#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-lan-guard.sh
source "$HERE/../lib/run-lan-guard.sh"
require_contains() {
    case "$2" in *"$3"*) ;; *)
        printf 'FAIL: %s\n' "$1" >&2
        exit 1
        ;;
    esac
}
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/box" "$TMP/out"
export TRACE="$TMP/trace" NODE_LISTENER=present NODE_PID=123 GUARD_RC=0 UNIT_FAIL=0 INSPECT_FAIL=0
export PATH="$TMP/bin:$PATH"
cat >"$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
[ "$INSPECT_FAIL" = 0 ] || { echo 'PASSWORD=secret'; exit 1; }
case "$*" in
*'{{.State.Pid}}'*) echo "$NODE_PID" ;;
*) echo 'true 0 2' ;;
esac
FAKE
cat >"$TMP/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
printf 'listener-read\n' >>"$TRACE"
case "$NODE_LISTENER" in
present) echo 'LISTEN 0 4096 secret-host:18142 203.0.113.42:0' ;;
absent) : ;;
hang) sleep 30 ;;
*) echo 'PASSWORD=secret'; exit 1 ;;
esac
FAKE
cat >"$TMP/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
[ "$UNIT_FAIL" = 0 ] || { echo 'PASSWORD=secret'; exit 1; }
printf '%s\n' 'LoadState=loaded' 'ActiveState=inactive' 'SubState=dead' 'Result=exit-code' 'ExecMainStatus=1' 'ExecMainStartTimestampMonotonic=123' 'ExecMainExitTimestampMonotonic=456' 'Description=secret-host' 'PASSWORD=secret' 'Result=203.0.113.42'
FAKE
cat >"$TMP/box/pithead" <<'FAKE'
lan_guard_enforced() { return "$GUARD_RC"; }
FAKE
chmod +x "$TMP/bin/"*
export IT_MODE=local IT_REMOTE_DIR="$TMP/box" OUT_DIR="$TMP/out"
TEST_CLOCK=0
now_s() { echo "$TEST_CLOCK"; }
sleep() {
    printf '%s\n' "$1" >>"$TMP/sleeps"
    TEST_CLOCK=$((TEST_CLOCK + $1))
}
_lan_probe() {
    printf 'probe\n' >>"$TRACE"
    if [ -n "${OPEN_AT:-}" ] && [ "$TEST_CLOCK" -ge "$OPEN_AT" ]; then
        echo open
    else
        echo "${PROBE_RESULT:-closed}"
    fi
}

echo "== LAN guard failure evidence =="
OUT_DIR="$TMP/delayed"
: >"$TRACE"
: >"$TMP/sleeps"
before="$IT_FAIL"
started_clock=$TEST_CLOCK
OPEN_AT=$((TEST_CLOCK + 10))
_lan_assert_open 'restarted listener becomes reachable' 10.254.254 18142 >"$TMP/transcript"
[ "$IT_FAIL" -eq "$before" ] && [ "$TEST_CLOCK" -eq "$((started_clock + 10))" ] || exit 1
[ "$(cat "$TMP/sleeps")" = $'5\n5' ] && [ "$(grep -cx probe "$TRACE")" -eq 4 ] || exit 1
require_contains 'initial failure retained before readiness' "$(cat "$TMP/transcript")" 'sample=initial'
require_contains 'actual dial eventually passed' "$(cat "$TMP/transcript")" 'elapsed_s=10 result=open'
if grep -q 'sample=timeout' "$TMP/transcript"; then exit 1; fi
unset OPEN_AT

OUT_DIR="$TMP/out"
TEST_CLOCK=0
: >"$TRACE"
: >"$TMP/sleeps"

_lan_assert_open 'closed probe remains failed' 10.254.254 18142 >"$TMP/transcript"
[ "$IT_FAIL" -eq 1 ] || exit 1
[ "$TEST_CLOCK" -eq 240 ] || exit 1
[ "$(wc -l <"$TMP/sleeps")" -eq 48 ] && [ "$(grep -cx probe "$TRACE")" -eq 50 ] || exit 1
if grep -qv '^5$' "$TMP/sleeps"; then exit 1; fi
require_contains 'deadline preserves failure' "$(cat "$TMP/transcript")" 'expected [open], got [closed]'
require_contains 'deadline sample retained' "$(cat "$TMP/transcript")" 'sample=timeout'
files=("$OUT_DIR/lan-guard/"*)
[ "${#files[@]}" -eq 2 ] || exit 1
for artifact in "${files[@]}"; do
    snapshot="$(cat "$artifact")"
    for expected in 'container=tari' 'running_exit_restarts=true 0 2' 'node_listener=present' 'guard=enforced' 'Result=exit-code' 'ExecMainStatus=1' 'ExecMainExitTimestampMonotonic=456'; do
        require_contains "$expected retained" "$snapshot" "$expected"
    done
    case "$artifact" in
    *-initial.*) sample=initial ;;
    *-timeout.*) sample=timeout ;;
    *) exit 1 ;;
    esac
    require_contains 'artifact sample attribution' "$snapshot" "sample=$sample"
    if grep -Eq 'secret|203\.0\.113|Description=' "$artifact" "$TMP/transcript"; then exit 1; fi
done
require_contains 'capture mirrored in transcript' "$(cat "$TMP/transcript")" 'lan-guard diagnostic: node_listener=present'
PROBE_RESULT=open
before="$IT_FAIL"
_lan_assert_open 'open probe passes' 10.254.254 18142 >"$TMP/transcript"
[ "$IT_FAIL" -eq "$before" ] && [ "$(find "$OUT_DIR/lan-guard" -type f | wc -l)" -eq 2 ] || exit 1
unset PROBE_RESULT

OUT_DIR="$TMP/immediate-control"
before="$IT_FAIL"
started_clock=$TEST_CLOCK
_lan_assert_open 'unguarded control remains immediate' 198.51.100 18142 0 >"$TMP/transcript"
[ "$IT_FAIL" -eq "$((before + 1))" ] && [ "$TEST_CLOCK" -eq "$started_clock" ] || exit 1
require_contains 'immediate control retains initial sample' "$(cat "$TMP/transcript")" 'sample=initial'
if grep -q 'sample=timeout' "$TMP/transcript"; then exit 1; fi
OUT_DIR="$TMP/out"

for listener in absent unavailable; do
    NODE_LISTENER="$listener"
    _lan_assert_open "listener $listener remains failed" 10.254.254 18142 >"$TMP/transcript"
    require_contains "listener $listener explicit" "$(cat "$TMP/transcript")" "node_listener=$listener"
done
NODE_LISTENER=hang
started=$SECONDS
_lan_assert_open 'hanging listener read remains failed' 10.254.254 18142 >"$TMP/transcript"
[ "$((SECONDS - started))" -le 12 ] || exit 1
require_contains 'hanging read explicit' "$(cat "$TMP/transcript")" 'node_listener=unavailable'
NODE_PID=0
: >"$TRACE"
_lan_assert_open 'stopped container remains failed' 10.254.254 18142 >"$TMP/transcript"
if grep -q listener-read "$TRACE"; then exit 1; fi
require_contains 'stopped container listener unavailable' "$(cat "$TMP/transcript")" 'node_listener=unavailable'
NODE_PID='123; PASSWORD=secret'
INSPECT_FAIL=1 UNIT_FAIL=1 GUARD_RC=1
_lan_assert_open 'failed reads remain failed' 10.254.254 18142 >"$TMP/transcript"
for expected in 'container_state=unavailable' 'node_listener=unavailable' 'guard=not-enforced-or-unavailable' 'lan_check=unavailable'; do
    require_contains "$expected explicit" "$(cat "$TMP/transcript")" "$expected"
done
if grep -Eq 'secret|203\.0\.113' "$TMP/transcript"; then exit 1; fi

before="$IT_FAIL"
rx() { return 124; }
_lan_assert_open 'transport timeout remains failed' 10.254.254 18142 >"$TMP/transcript"
[ "$IT_FAIL" -eq "$((before + 3))" ] || exit 1
require_contains 'timeout explicit' "$(cat "$TMP/transcript")" 'capture-exit=124'
rx() {
    printf 'x %.0s' {1..5000}
    printf '\n'
}
before="$IT_FAIL"
_lan_assert_open 'oversized capture remains bounded' 10.254.254 18142 >"$TMP/transcript"
latest=$(ls -t "$OUT_DIR/lan-guard/"* | head -n 1)
[ "$(wc -c <"$latest")" -eq 8192 ] || exit 1
[ "$IT_FAIL" -ge "$((before + 1))" ] || exit 1
OUT_DIR="$TMP/not-directory"
: >"$OUT_DIR"
before="$IT_FAIL"
_lan_assert_open 'write failure remains failed' 10.254.254 18142 >"$TMP/transcript" 2>/dev/null
[ "$IT_FAIL" -eq "$((before + 3))" ] || exit 1
require_contains 'write failure explicit' "$(cat "$TMP/transcript")" 'could not create artifact'

IT_FAIL=0
wait_for() {
    shift 3
    "$@"
}
rx() {
    if [ "${2:-}" = --stdin ]; then
        printf 'snapshot\n' >>"$TRACE"
        printf 'node_listener=absent\n'
    else
        case "$1" in
        *container_engine*) echo docker ;;
        *'restart pithead-lan-guard.service'*) printf 'restore\n' >>"$TRACE" ;;
        *) : ;;
        esac
    fi
}
_lan_strip() { printf 'strip\n' >>"$TRACE"; }
env_on_box() { echo false; }
OUT_DIR="$TMP/order"
: >"$TRACE"
assert_lan_guard_boot_restore 18142 >"$TMP/transcript"
[ "$(cat "$TRACE")" = 'probe
snapshot
probe
snapshot
strip
probe
snapshot
restore
probe
probe
snapshot
probe
snapshot' ] || {
    cat "$TRACE"
    exit 1
}
require_contains 'original control failure preserved' "$(cat "$TMP/transcript")" 'control: with the rule gone, a non-private source reaches port 18142'
echo 'selftest-lan-guard-evidence: PASS'
