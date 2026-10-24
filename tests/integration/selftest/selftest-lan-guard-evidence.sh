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
_lan_probe() {
    printf 'probe\n' >>"$TRACE"
    echo "${PROBE_RESULT:-closed}"
}

_lan_assert_open 'closed probe remains failed' 10.254.254 18142 >"$TMP/transcript"
[ "$IT_FAIL" -eq 1 ] || exit 1
files=("$OUT_DIR/lan-guard/"*)
[ "${#files[@]}" -eq 1 ] || exit 1
snapshot="$(cat "${files[0]}")"
for expected in 'container=tari' 'running_exit_restarts=true 0 2' 'node_listener=present' 'guard=enforced' 'Result=exit-code' 'ExecMainStatus=1' 'ExecMainExitTimestampMonotonic=456'; do
    require_contains "$expected retained" "$snapshot" "$expected"
done
if grep -Eq 'secret|203\.0\.113|Description=' "${files[0]}" "$TMP/transcript"; then exit 1; fi
require_contains 'capture mirrored in transcript' "$(cat "$TMP/transcript")" 'lan-guard diagnostic: node_listener=present'
PROBE_RESULT=open
before="$IT_FAIL"
_lan_assert_open 'open probe passes' 10.254.254 18142 >"$TMP/transcript"
[ "$IT_FAIL" -eq "$before" ] && [ "$(find "$OUT_DIR/lan-guard" -type f | wc -l)" -eq 1 ] || exit 1
unset PROBE_RESULT

for listener in absent unavailable; do
    NODE_LISTENER="$listener"
    _lan_assert_open "listener $listener remains failed" 10.254.254 18142 >"$TMP/transcript"
    require_contains "listener $listener explicit" "$(cat "$TMP/transcript")" "node_listener=$listener"
done
NODE_LISTENER=hang
started=$SECONDS
_lan_assert_open 'hanging listener read remains failed' 10.254.254 18142 >"$TMP/transcript"
[ "$((SECONDS - started))" -le 8 ] || exit 1
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
[ "$IT_FAIL" -eq "$((before + 2))" ] || exit 1
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
[ "$IT_FAIL" -eq "$((before + 2))" ] || exit 1
require_contains 'write failure explicit' "$(cat "$TMP/transcript")" 'could not create artifact'

IT_FAIL=0
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
[ "$(cat "$TRACE")" = 'strip
probe
snapshot
restore
probe
probe
snapshot' ] || {
    cat "$TRACE"
    exit 1
}
require_contains 'original control failure preserved' "$(cat "$TMP/transcript")" 'control: with the rule gone, a non-private source reaches port 18142'
echo 'selftest-lan-guard-evidence: PASS'
