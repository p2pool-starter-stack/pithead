#!/usr/bin/env bash
set -euo pipefail
umask 077
exec 2>&1
stage=scratch
probe_failure() { printf 'restore dashboard probe failed at %s (exit %s)\n' "$stage" "$1"; }
scratch=$(mktemp -d "${TMPDIR:-$PWD/data}/restore-dashboard.XXXXXXXX") || {
    probe_failure "$?"
    exit 1
}
archive=""
mutated=0
stage=baseline-snapshot
if ! cp config.json "$scratch/original.json"; then
    probe_failure 1
    rm -f -- "$scratch/original.json"
    rmdir "$scratch"
    exit 1
fi
wait_cleanup_health() {
    local deadline=$((SECONDS + 240)) stable=0
    while [ "$SECONDS" -lt "$deadline" ]; do
        if timeout 30 ./pithead status >/dev/null 2>&1; then stable=$((stable + 1)); else stable=0; fi
        [ "$stable" -lt 2 ] || return 0
        sleep 3
    done
    printf 'restore dashboard cleanup: health did not recover\n' >&2
    return 1
}
cleanup() {
    local result=$? verified=1
    trap - EXIT
    [ "$result" -eq 0 ] || probe_failure "$result"
    if [ "$mutated" -eq 1 ]; then
        ./pithead down || verified=0
        if cp "$scratch/original.json" config.json && ./pithead apply -y && ./pithead up; then
            wait_cleanup_health || verified=0
        else
            verified=0
        fi
    fi
    cmp -s "$scratch/original.json" config.json || verified=0
    if [ "$verified" -eq 1 ]; then
        [ -z "$archive" ] || rm -f -- "$archive" || result=1
        rm -f -- "$scratch/original.json" "$scratch/fixture.json" "$scratch/config.json" "$scratch/password" "$scratch/backup.log" "$scratch/before" || result=1
        rmdir "$scratch" || result=1
    else
        printf 'restore dashboard cleanup unverified; private recovery fixture retained\n' >&2
        result=1
    fi
    exit "$result"
}
trap cleanup EXIT
stage=fixture-projection
jq --slurpfile original "$scratch/original.json" '
    def candidate($saved):
        with_entries(select(.key != "_docs" and .key != "config_version") |
            .key as $key |
            select(($saved | type) == "object" and ($saved | has($key))) |
            .value |= if type == "object" then candidate($saved[$key]) else $saved[$key] end);
    candidate($original[0])
' config.reference.json >"$scratch/fixture.json"
jq -e --slurpfile original "$scratch/original.json" '
    . as $fixture |
    all($original[0] | paths(scalars) | select(any(.[]; type == "string" and test("wallet|payout|view_key|spend_public_key|donor_id")));
        . as $path | $fixture | getpath($path) == ($original[0] | getpath($path)))
' "$scratch/fixture.json" >/dev/null || {
    printf 'restore dashboard fixture cannot preserve every wallet and payout field\n' >&2
    exit 1
}
mutated=1
stage=fixture-install
cp "$scratch/fixture.json" config.json
stage=fixture-password
openssl rand -hex 24 >"$scratch/password"
set_cost() {
    jq --argjson cost "$1" --rawfile password "$scratch/password" '.dashboard.energy.cost_per_kwh = $cost | .dashboard.control.enabled = true | if (.dashboard.auth.password // "") == "" then .dashboard.auth.password = ($password | rtrimstr("\n")) else . end | .dashboard.onion.client_auth = true' config.json >"$scratch/config.json"
    cp "$scratch/config.json" config.json
    ./pithead apply -y
}
wait_cost() {
    local endpoint="$1" query="$2" expected="$3" deadline=$((SECONDS + 120))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if curl -fsS --max-time 5 "http://127.0.0.1:8000/api/$endpoint" |
            jq -e --argjson expected "$expected" "$query == \$expected" >/dev/null; then
            return 0
        fi
        sleep 2
    done
    printf 'restore dashboard: /api/%s did not report expected cost\n' "$endpoint" >&2
    return 1
}
stage=fixture-apply
set_cost 0.123
stage=backup
mkdir -p backups
find "$PWD/backups" -maxdepth 1 -type f -print >"$scratch/before"
if ! NO_COLOR=1 ./pithead backup -y --no-encrypt >"$scratch/backup.log" 2>&1; then
    printf 'restore dashboard: backup failed\n' >&2
    exit 1
fi
mapfile -t created < <(sed -n 's/^\[pithead\] Backup written to: //p' "$scratch/backup.log")
[ "${#created[@]}" -eq 1 ]
case "${created[0]}" in "$PWD/backups/pithead-backup-"*.tar.gz) ;; *) exit 1 ;; esac
if grep -Fxq -- "${created[0]}" "$scratch/before"; then
    printf 'restore dashboard: backup replaced an existing archive\n' >&2
    exit 1
fi
test -f "${created[0]}"
archive="${created[0]}"
stage=changed-apply
set_cost 0.789
stage=changed-config-api
wait_cost config .dashboard.energy.cost_per_kwh 0.789
stage=down
./pithead down
stage=restore
./pithead restore -y "$archive"
stage=up
./pithead up
stage=archived-api-assertions
config_rc=0 state_rc=0
wait_cost config .dashboard.energy.cost_per_kwh 0.123 || config_rc=$?
wait_cost state .energy.cost_per_kwh 0.123 || state_rc=$?
[ "$config_rc" -eq 0 ] && [ "$state_rc" -eq 0 ]
