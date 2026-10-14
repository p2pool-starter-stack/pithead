#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/../lib/node-recovery-evidence.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/node-recovery.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
export RECOVERY_TEST_DIR="$TEST_DIR"
# shellcheck disable=SC2034 # Serialized by the collector transport.
IT_MODE=local IT_REMOTE_DIR="$TEST_DIR" IT_PITHEAD=pithead
OUT_DIR="$TEST_DIR/results"
mkdir -p "$OUT_DIR"
export RECOVERY_TEST_RC=19
now_s() { cat "$TEST_DIR/clock"; }
wait_status_ok() {
    [ "$1" = 240 ] || exit 99
    printf 250 >"$TEST_DIR/clock"
    return "${RECOVERY_WAIT_RC:-1}"
}
rx() {
    if [ "$1" != 'pithead status' ] && [ "${RECOVERY_PROBE_RC:-0}" != 0 ]; then
        printf 'unavailable private response'
        return "$RECOVERY_PROBE_RC"
    fi
    case "$1" in
        'pithead status')
            echo status >>"$RECOVERY_TEST_DIR/calls"
            printf '  ⚠ monerod       running but UNHEALTHY\n'
            printf '  ✗ tari          restarting (possible crash loop — check logs)\n' >&2
            echo 'private arbitrary credential and topology must be omitted'
            return "$RECOVERY_TEST_RC"
            ;;
        curl*) printf '{"syncing":true,"pool":{"type":"Mini","syncing":true},"sync":{"monero":{"state":"syncing","current":12,"target":15},"tari":{"state":"done"}},"monero":{"health":{"level":"red"}},"host_addr":"private-value"}' ;;
        docker*) printf '{"service":"/monerod","state":"running","health":"unhealthy","restarts":3,"exit_code":0,"oom_killed":false,"secret":"private-value"}\n' ;;
    esac
}
printf 10 >"$TEST_DIR/clock"
assert_node_recovery_status >"$TEST_DIR/assertion.log" || exit 1
[ "$IT_FAIL" = 1 ] && [ "$(wc -l <"$TEST_DIR/calls")" -eq 1 ] || exit 1
python3 - "$OUT_DIR/node-recovery.failure.json" <<'PY'
import json
import sys
s = json.load(open(sys.argv[1]))
assert s["status"]["exit_code"] == 19
assert s["wait_exit_code"] == 1 and s["wait_elapsed_seconds"] == 240
assert len(s["status"]["output"]["service_verdict_lines"]) == 2
assert s["status"]["output"]["omitted_lines"] == 1
assert s["dashboard"]["projection"]["syncing"] is True
assert s["dashboard"]["projection_available"] is True
assert s["services"]["projection"]["monerod"]["restarts"] == 3
assert s["services"]["projection_available"] is False  # only one of six returned
assert "private" not in json.dumps(s)
PY
[ "$?" = 0 ] || exit 1
# Success keeps the same single status invocation and adds no failure artifact.
RECOVERY_WAIT_RC=0 RECOVERY_TEST_RC=0 OUT_DIR="$TEST_DIR/success"
printf 10 >"$TEST_DIR/clock"
assert_node_recovery_status >"$TEST_DIR/success.log" || exit 1
[ "$IT_FAIL" = 1 ] && [ ! -e "$OUT_DIR/node-recovery.failure.json" ] || exit 1
[ "$(wc -l <"$TEST_DIR/calls")" -eq 2 ] || exit 1
# Failed persistence adds an evidence failure without changing the original status row.
RECOVERY_TEST_RC=23 OUT_DIR="$TEST_DIR/unwritable"
printf 'not a directory' >"$OUT_DIR"
printf 10 >"$TEST_DIR/clock"
assert_node_recovery_status >"$TEST_DIR/write-failed.log" 2>"$TEST_DIR/write-failed.err" || exit 1
[ "$IT_FAIL" = 3 ] || exit 1
grep -q 'expected rc 0, got 23' "$TEST_DIR/write-failed.log" || exit 1
grep -q 'node recovery failure evidence captured' "$TEST_DIR/write-failed.log" || exit 1
# Probe refusal remains explicit and cannot overwrite the original failure.
export RECOVERY_PROBE_RC=7
RECOVERY_TEST_RC=31 OUT_DIR="$TEST_DIR/probe-failed"
printf 10 >"$TEST_DIR/clock"
assert_node_recovery_status >"$TEST_DIR/probe-failed.log" || exit 1
python3 - "$OUT_DIR/node-recovery.failure.json" <<'PYPROBE'
import json
import sys
s = json.load(open(sys.argv[1]))
assert s["status"]["exit_code"] == 31
for kind in ("dashboard", "services"):
    assert s[kind]["exit_code"] == 7
    assert s[kind]["projection_available"] is False
assert "private" not in json.dumps(s)
PYPROBE
[ "$?" = 0 ] && [ "$IT_FAIL" = 4 ] || exit 1
RECOVERY_PROBE_RC=0
python3 "$HERE/test-node-recovery-evidence.py" || exit 1
# Exercise the actual lifecycle block: capture must precede its next mutation.
LIFECYCLE_BLOCK="$(sed -n '/^    # Node-down failover/,/^    # backup → restore/p' "$HERE/../lib/run-lifecycle.sh" | sed '$d')"
[ -n "$LIFECYCLE_BLOCK" ] || exit 1
OUT_DIR="$TEST_DIR/ordering" RECOVERY_TEST_RC=29
has_compose_profile() { return 0; }
env_on_box() { echo local_node; }
wait_for() { :; }
pithead() {
    if [ "$1" = backup ]; then
        [ -s "$OUT_DIR/node-recovery.failure.json" ] || exit 1
        return 0
    fi
    return 1
}
printf 10 >"$TEST_DIR/clock"
eval "$LIFECYCLE_BLOCK" >"$TEST_DIR/ordering.log"
pithead backup || exit 1
[ -s "$OUT_DIR/node-recovery.failure.json" ] || exit 1
grep -q 'status OK after node recovery' "$TEST_DIR/ordering.log" || exit 1
[ "$IT_FAIL" = 5 ] || exit 1
printf 'node recovery boundary regressions passed\n'
