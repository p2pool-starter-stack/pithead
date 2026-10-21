#!/usr/bin/env bash
set -euo pipefail
umask 077
scratch=$(mktemp -d "${TMPDIR:-$PWD/data}/restore-dashboard.XXXXXXXX")
archive=""
cp config.json "$scratch/original.json"
cleanup() {
    local result=$?
    trap - EXIT
    ./pithead down || result=1
    if ! { cp "$scratch/original.json" config.json && ./pithead apply -y && ./pithead up; }; then
        result=1
    fi
    [ "$result" -eq 0 ] || printf 'restore dashboard fixture failed or cleanup did not complete\n' >&2
    [ -z "$archive" ] || rm -f -- "$archive"
    rm -f -- "$scratch/original.json" "$scratch/config.json" "$scratch/password" "$scratch/backup.log" "$scratch/before"
    rmdir "$scratch"
    exit "$result"
}
trap cleanup EXIT
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
set_cost 0.123
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
set_cost 0.789
wait_cost config .dashboard.energy.cost_per_kwh 0.789
./pithead down
./pithead restore -y "$archive"
./pithead up
config_rc=0 state_rc=0
wait_cost config .dashboard.energy.cost_per_kwh 0.123 || config_rc=$?
wait_cost state .energy.cost_per_kwh 0.123 || state_rc=$?
[ "$config_rc" -eq 0 ] && [ "$state_rc" -eq 0 ]
