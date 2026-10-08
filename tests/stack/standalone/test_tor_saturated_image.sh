#!/usr/bin/env bash
# Offline state-write behavior of the actual Tor image; run by image CI.
set -euo pipefail
echo "== Tor image offline saturated-state recovery =="
log=$(mktemp "${TMPDIR:?}/tor-offline.XXXXXX")
trap 'rm -f "$log"' EXIT
docker run -i --rm --network none --entrypoint sh "${1:?Tor image required}" -s <<'GUEST' | tee "$log"
set -eu
phase='configure offline fixture'
diagnostics() {
    result=$?
    trap - EXIT
    set +e
    if [ "$result" -ne 0 ]; then
        printf 'FAIL: offline Tor phase: %s (exit %s)\n' "$phase" "$result" >&2
        # Only the isolated fixture's daemon log and CBT fields; never its auth cookie.
        if [ -f "$dir/offline.log" ]; then
            echo 'Offline Tor log (last 80 lines):' >&2
            tail -n 80 "$dir/offline.log" >&2
        fi
        if [ -f "$dir/state" ]; then
            echo 'Offline Tor circuit-build state:' >&2
            grep -E '^(CircuitBuildAbandonedCount|TotalBuildTimes|CircuitBuildTimeBin) ' "$dir/state" >&2 || :
        fi
    fi
    exit "$result"
}
trap diagnostics EXIT
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
start() {
    phase="tor -f offline.torrc"
    tor -f "$dir/offline.torrc"
    phase="authenticated GETINFO version readiness (30 attempts)"
    for i in $(seq 1 30); do
        cookie=$(xxd -p -c 256 "$dir/control_auth_cookie" 2>/dev/null) || cookie=""
        reply=$(printf 'AUTHENTICATE %s\r\nGETINFO version\r\nQUIT\r\n' "$cookie" |
            nc -w 3 127.0.0.1 9051 2>/dev/null) || reply=""
        if [ -s "$dir/pid" ] && kill -0 "$(cat "$dir/pid")" 2>/dev/null &&
            [ "$(printf '%s\n' "$reply" | grep -c '^250 OK')" = 2 ]; then
            return 0
        fi
        sleep 1
    done
    echo 'Tor offline start did not become ready' >&2
    return 1
}
stop() {
    phase="read offline Tor pid file"
    process=$(cat "$dir/pid")
    phase="kill -TERM offline Tor pid"
    kill -TERM "$process"
    phase="wait for process, pid file and control listener to stop"
    for i in $(seq 1 30); do
        if ! kill -0 "$process" 2>/dev/null && [ ! -e "$dir/pid" ] &&
            ! nc -z -w 1 127.0.0.1 9051; then
            return 0
        fi
        sleep 1
    done
    echo 'Tor offline stop did not fully settle' >&2
    return 1
}
seed
start
phase='classify saturated-history startup'
if grep -q 'CBT history has no completed observations; restarting conservative learning. samples=1000 abandoned=1000 usable=0' "$dir/offline.log"; then
    repaired=true
    echo 'PASS: Tor reports automatic repair of all 1000 abandoned observations'
else
    grep -q 'No valid circuit build time data' "$dir/offline.log"
    repaired=false
    echo 'PASS: saturated history emits the invalid build-time warning offline'
fi
health=0
/usr/local/bin/tor-healthcheck.sh || health=$?
printf 'Offline DisableNetwork healthcheck exit: %s\n' "$health"
if [ "$repaired" = true ]; then
    stop
    phase='test -s state after automatic repair'
    [ -s "$dir/state" ]
    # Tor's minimal state writer omits fields equal to their zero defaults.
    for field in CircuitBuildAbandonedCount TotalBuildTimes; do
        phase="assert $field is absent or zero after automatic repair"
        awk -v field="$field" '$1 == field && ($2 != "0" || NF != 2) { bad=1 } END { exit bad }' "$dir/state"
    done
    phase='assert no CircuitBuildTimeBin after automatic repair'
    ! grep -q '^CircuitBuildTimeBin ' "$dir/state"
    echo 'PASS: automatic repair persists an empty circuit-build history'
else
    phase='move state while Tor runs'
    mv "$dir/state" "$dir/state.exec-backup"
    stop
    phase='verify shutdown restores saturated history'
    saturated
    start
    phase='verify saturated history survives restart'
    saturated
    echo 'PASS: moving state while Tor runs is undone by its shutdown write'
    stop
fi
phase='move state after stopping Tor'
mv "$dir/state" "$dir/state.stopped-backup"
start
stop
phase='verify stop, move, start clears saturated history'
[ -s "$dir/state" ]
! saturated
echo 'PASS: stop, move, start clears the saturated state'
echo 'Tor offline recovery assertions complete'
GUEST
grep -qx 'Tor offline recovery assertions complete' "$log"
