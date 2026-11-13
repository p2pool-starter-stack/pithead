#!/usr/bin/env bash
set -Eeuo pipefail
stage=initialization
trap 'printf "Tor heal exhausted guest failed at %s (line %s, exit %s)\n" "$stage" "$LINENO" "$?" >&2' ERR
cd /data/pithead
control=$(sed -n 's/^CONTROL_DIR=//p' .env)
data=$(sed -n 's/^TOR_DATA_DIR=//p' .env)
[ -d "$control" ] && [ -d "$data" ]
export TMPDIR="$control/work"
mkdir -p "$TMPDIR"
work=$(mktemp -d "$TMPDIR/tor-heal-exhausted.XXXXXX")
cp config.json "$work/config.json"
cp "$data/state" "$work/original-state"
identities() {
    find "$data" -type f -name hs_ed25519_secret_key -exec sha256sum {} + | sort
}
identities >"$work/identities"
[ -s "$work/identities" ]
restore() {
    local rc=$? restored=0 logfile
    trap - EXIT ERR
    cp "$work/config.json" config.json || restored=1
    rm -f "$control/tor-newnym-budget"
    docker compose restart tor >"$work/restore-restart.log" 2>&1 || restored=1
    ./pithead apply -y >"$work/restore.log" 2>&1 || restored=1
    if [ "$rc" != 0 ] || [ "$restored" != 0 ]; then
        for logfile in "$work"/*.log; do
            [ -f "$logfile" ] || continue
            printf 'Guest command log: %s\n' "${logfile##*/}"
            tail -c 4096 "$logfile" || true
        done
    fi
    printf 'Guest restoration exit: %s; original exit: %s\n' "$restored" "$rc"
    if [ "$rc" = 0 ] && [ "$restored" != 0 ]; then rc=1; fi
    exit "$rc"
}
trap restore EXIT
saturated() {
    grep -qx 'CircuitBuildAbandonedCount 1000' "$1" &&
        grep -qx 'TotalBuildTimes 1000' "$1" &&
        ! grep -q '^CircuitBuildTimeBin ' "$1"
}
backup_count() {
    find "$data" -maxdepth 1 -name 'state.backup.*' -type f | wc -l
}
stage=configure-enabled
jq '.tor.auto_heal=true' config.json >"$work/next-config"
cp "$work/next-config" config.json
./pithead apply -y >"$work/apply.log" 2>&1
! saturated "$data/state"
before=$(backup_count)
stage=spend-newnym-budget
printf '%s 2\n' "$(date +%s)" >"$control/tor-newnym-budget"
stage=black-hole-tor
started=$(date +%s)
reply=$(docker exec tor sh -c '
    cookie=$(xxd -p -c 256 /var/lib/tor/control_auth_cookie)
    printf "AUTHENTICATE %s\r\nSETCONF DisableNetwork=1\r\nQUIT\r\n" "$cookie" |
        nc -w 3 127.0.0.1 9051' | tr -d '\r')
[ "$(printf '%s\n' "$reply" | grep -c '^250 OK$')" = 2 ]
stage=host-reset
deadline=$((started + 95 * 60))
applied=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if find "$control/results" -maxdepth 1 -name '*.json' -type f -exec \
        jq -e --argjson started "$started" 'select(.action == "tor-recover" and .status == "applied" and .ts >= $started)' {} \; 2>/dev/null |
        grep 'tor-recover' >/dev/null; then
        applied=1
        break
    fi
    sleep 30
done
[ "$applied" = 1 ]
stage=verify-recovery
grep -q '"action":"tor-newnym","status":"rejected"' "$control/audit/control.log"
[ "$(backup_count)" -gt "$before" ]
stamp=$(cat "$control/tor-recovery-at")
! saturated "$data/state.backup.$stamp"
[ -s "$data/state" ]
identities >"$work/after-identities"
cmp "$work/identities" "$work/after-identities"
docker exec tor /usr/local/bin/tor-healthcheck.sh
echo 'PASS: a rejected NEWNYM advances to a host state reset on an unsaturated history and Tor recovers unattended (#4075)'
