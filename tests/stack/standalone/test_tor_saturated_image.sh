#!/usr/bin/env bash
# Offline state-write behavior of the actual Tor image; run by image CI.
set -euo pipefail
echo "== Tor image offline saturated-state recovery =="
log=$(mktemp "${TMPDIR:?}/tor-offline.XXXXXX")
trap 'rm -f "$log"' EXIT
docker run -i --rm --network none --entrypoint sh "${1:?Tor image required}" -s <<'GUEST' | tee "$log"
set -eu
dir=/var/lib/tor
printf 'DataDirectory %s\nDisableNetwork 1\nControlPort 127.0.0.1:9051\nCookieAuthentication 1\nCookieAuthFile %s/control_auth_cookie\nRunAsDaemon 1\nPidFile %s/pid\nLog notice file %s/offline.log\n' "$dir" "$dir" "$dir" "$dir" >"$dir/offline.torrc"
seed() {
    printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >"$dir/state"
}
saturated() {
    grep -qx 'CircuitBuildAbandonedCount 1000' "$dir/state" &&
        grep -qx 'TotalBuildTimes 1000' "$dir/state" &&
        ! grep -q '^CircuitBuildTimeBin ' "$dir/state"
}
start() { tor -f "$dir/offline.torrc"; }
stop() {
    process=$(cat "$dir/pid")
    kill -TERM "$process"
    for i in $(seq 1 30); do
        if ! kill -0 "$process" 2>/dev/null; then
            [ ! -e "$dir/pid" ]
            ! nc -z -w 1 127.0.0.1 9051
            return 0
        fi
        sleep 1
    done
    return 1
}
seed
start
grep -q 'No valid circuit build time data' "$dir/offline.log"
echo 'PASS: saturated history emits the invalid build-time warning offline'
health=0
/usr/local/bin/tor-healthcheck.sh || health=$?
printf 'Offline DisableNetwork healthcheck exit: %s\n' "$health"
mv "$dir/state" "$dir/state.exec-backup"
stop
saturated
start
saturated
echo 'PASS: moving state while Tor runs is undone by its shutdown write'
stop
mv "$dir/state" "$dir/state.stopped-backup"
start
stop
[ -s "$dir/state" ]
! saturated
echo 'PASS: stop, move, start clears the saturated state'
echo 'Tor offline recovery assertions complete'
GUEST
grep -qx 'Tor offline recovery assertions complete' "$log"
