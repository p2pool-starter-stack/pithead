#!/usr/bin/env bash
# Execute e2e.sh's real detached-launch transport without a bench.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# run_harness calls harness_pregate / harness_install_runner; source the REAL ones rather than
# re-spelling them, for the same reason the function itself is extracted and not re-implemented.
# shellcheck source=tests/integration/lib/detached-harness.sh
source "$HERE/../lib/detached-harness.sh"
contains() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac }
HARNESS_SRC="$(sed -n '/^run_harness() {$/,/^}$/p' "$HERE/../e2e.sh")"
assert_eq "the extraction is the whole run_harness function" \
    "$(printf '%s\n' "$HARNESS_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "run_harness() { } "

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LAUNCH_FILE="$WORK/launch" STDIN_FILE="$WORK/stdin" PREPARE_FILE="$WORK/prepare"
# The payout-confirm keys come from the caller's environment; start from none, whatever CI exports.
unset IT_MONERO_VIEW_KEY IT_TARI_VIEW_KEY IT_TARI_SPEND_PUBLIC_KEY

capture_launch() { # <rollback> <pools> [rig-lock-wait]; the IT_*_VIEW_KEY globals pass through
    : >"$LAUNCH_FILE"
    : >"$STDIN_FILE"
    rm -f "$PREPARE_FILE"
    (
        # Nothing in here may read the SCRIPT's stdin: the on_bench stub's fall-through `cat` would
        # then block forever on an inherited terminal, and a hang reads as a test that never
        # finished rather than one that failed. Same guard as selftest-e2e-phases.sh.
        exec </dev/null
        # shellcheck disable=SC2034 # read by the eval'd real run_harness
        MODE=matrix BORROW_MINER=0 WORKERS=1 BENCH_HOST=bench E2E_DIR=/srv/code/pithead-e2e SCENARIO="" RIG_LOCK_WAIT="${3:-}"
        # shellcheck disable=SC2034 # read by the eval'd real run_harness
        REMOTE_NODE_ARGS=() REMOTE_NODE_HOSTS=()
        # shellcheck disable=SC2034 # read by the eval'd real run_harness
        IT_RIG_TOKEN=tok IT_RIG_ROLLBACK_CHANGES="$1" IT_RIG_POOLS_PROBE="$2"
        # shellcheck disable=SC2034 # read by the eval'd real run_harness
        RIG_LOCK_PARENT_ACTOR=actor RIG_LOCK_PARENT_NONCE=0123456789abcdef0123456789abcdef
        log() { :; }
        step() { :; }
        warn() { :; }
        ok() { :; }
        die() { exit 1; }
        harness_prepare() {
            # shellcheck disable=SC2034 # read by the eval'd real run_harness
            HARNESS_STATE=/test/state
            : >"$PREPARE_FILE"
        }
        harness_finished() { :; }
        on_bench() {
            case "$1" in
            *nohup*)
                printf '%s' "$1" >"$LAUNCH_FILE"
                cat >"$STDIN_FILE"
                echo 4242
                ;;
            *e2e-harness.done*) echo 0 ;;
            *) cat >/dev/null ;;
            esac
        }
        eval "$HARNESS_SRC"
        run_harness >/dev/null 2>&1
    )
}

execute_launch() { # <stdin-file> <capture-file>
    # env -u: the launched runner must see only what the stream carried, never this shell's exports.
    CAPTURE_FILE="$2" LIB="$HERE/../lib.sh" env -u IT_MONERO_VIEW_KEY -u IT_TARI_VIEW_KEY -u IT_TARI_SPEND_PUBLIC_KEY bash -c '
        rm() { :; }; cd() { :; }
        grep() { test -s "$CAPTURE_FILE"; }
        nohup() {
            printf "ROLLBACK_BEGIN\n%s\nROLLBACK_END\nPOOLS_BEGIN\n%s\nPOOLS_END\nRIG_LOCK_WAIT=%s\nMONERO_VIEW_KEY=%s\nTARI_VIEW_KEY=%s\nTARI_SPEND_PUBLIC_KEY=%s\nARGV[%s]\n" \
                "$IT_RIG_ROLLBACK_CHANGES" "$IT_RIG_POOLS_PROBE" "$RIG_LOCK_WAIT" "$IT_MONERO_VIEW_KEY" "$IT_TARI_VIEW_KEY" "$IT_TARI_SPEND_PUBLIC_KEY" "$*" >"$CAPTURE_FILE"
            # The harness-side consumer, fed the environment the runner received.
            # shellcheck source=tests/integration/lib.sh
            source "$LIB"
            if resolve_overrides "payout_confirm=env"; then
                printf "PAYOUT_CONFIRM=run [%s]\n" "$RESOLVED" >>"$CAPTURE_FILE"
            else
                printf "PAYOUT_CONFIRM=skip [%s]\n" "$SKIP_REASON" >>"$CAPTURE_FILE"
            fi
        }
        eval "$1"
    ' _ "$(cat "$LAUNCH_FILE")" <"$1" >/dev/null
}

echo "== exact eight-record transport, multiline decode, environment, and argv hygiene =="
ROLLBACK=$'{"pools":[\n{"url":"127.0.0.1:1"}]}' POOLS='[{"url":"probe:1"}]'
capture_launch "$ROLLBACK" "$POOLS"
assert_eq "the producer emits exactly eight records" "$(awk 'END {print NR}' "$STDIN_FILE")" 8
EXPECTED="$(printf 'tok\nactor\n0123456789abcdef0123456789abcdef\n%s\n%s\n\n\n' \
    'eyJwb29scyI6Wwp7InVybCI6IjEyNy4wLjAuMToxIn1dfQ==' 'W3sidXJsIjoicHJvYmU6MSJ9XQ==')"
assert_eq "record values and order are exact" "$(cat "$STDIN_FILE")" "$EXPECTED"
execute_launch "$STDIN_FILE" "$WORK/captured"
CAPTURED="$(cat "$WORK/captured")" ARGV="$(sed -n 's/^ARGV\[\(.*\)\]$/\1/p' "$WORK/captured")"
assert_contains "multiline rollback input reaches the runner environment intact" "$CAPTURED" "$(printf 'ROLLBACK_BEGIN\n%s\nROLLBACK_END' "$ROLLBACK")"
assert_contains "pools input reaches the runner environment intact" "$CAPTURED" "$(printf 'POOLS_BEGIN\n%s\nPOOLS_END' "$POOLS")"
assert_eq "rollback input stays out of runner argv" "$(contains "$ARGV" "$ROLLBACK")" no
assert_eq "pools input stays out of runner argv" "$(contains "$ARGV" "$POOLS")" no
assert_contains "the default lock setting reaches the detached runner" "$CAPTURED" "RIG_LOCK_WAIT=0"
capture_launch "$ROLLBACK" "$POOLS" 0
execute_launch "$STDIN_FILE" "$WORK/no-wait"
assert_contains "an explicit no-wait setting reaches the detached runner" "$(cat "$WORK/no-wait")" "RIG_LOCK_WAIT=0"
capture_launch "$ROLLBACK" "$POOLS" 1
execute_launch "$STDIN_FILE" "$WORK/wait"
assert_contains "the bench lock-wait setting reaches the detached runner" "$(cat "$WORK/wait")" "RIG_LOCK_WAIT=1"

echo "== payout-confirm view keys reach the harness environment, never argv (#2675) =="
assert_contains "unset view keys arrive empty" "$CAPTURED" $'MONERO_VIEW_KEY=\nTARI_VIEW_KEY=\nTARI_SPEND_PUBLIC_KEY=\n'
assert_contains "unset view keys leave the payout-confirm row skipped" "$CAPTURED" "PAYOUT_CONFIRM=skip [needs IT_MONERO_VIEW_KEY"
MVK=mvk-0123456789abcdef TVK=tvk-fedcba9876543210 TSPK=tspk-00112233445566778899
IT_MONERO_VIEW_KEY="$MVK" IT_TARI_VIEW_KEY="$TVK" IT_TARI_SPEND_PUBLIC_KEY="$TSPK" capture_launch "$ROLLBACK" "$POOLS"
assert_eq "the keys are the last three records, in order" "$(tail -n 3 "$STDIN_FILE")" "$(printf '%s\n%s\n%s' "$MVK" "$TVK" "$TSPK")"
execute_launch "$STDIN_FILE" "$WORK/keys"
KEYS="$(cat "$WORK/keys")"
assert_contains "the wrapper's view keys reach the runner environment" "$KEYS" \
    "$(printf 'MONERO_VIEW_KEY=%s\nTARI_VIEW_KEY=%s\nTARI_SPEND_PUBLIC_KEY=%s' "$MVK" "$TVK" "$TSPK")"
assert_contains "the harness runs the payout-confirm row with all three keys" "$KEYS" \
    "PAYOUT_CONFIRM=run [monero.view_key=$MVK tari.view_key=$TVK tari.spend_public_key=$TSPK]"
for k in "$MVK" "$TVK" "$TSPK"; do
    assert_eq "view key ${k%%-*} stays off the remote command line" "$(contains "$(cat "$LAUNCH_FILE")" "$k")" no
done
IT_MONERO_VIEW_KEY=$'mvk\nextra' capture_launch "$ROLLBACK" "$POOLS"
assert_eq "a view key with a newline refuses to launch" "$?" 1
assert_eq "a view key with a newline never reaches the remote launch" "$(if [ -s "$LAUNCH_FILE" ]; then echo 1; else echo 0; fi)" 0

echo "== empty values remain supplied, while missing records and encoder errors fail closed =="
capture_launch "" ""
execute_launch "$STDIN_FILE" "$WORK/empty"
assert_contains "empty rollback survives as an environment entry" "$(cat "$WORK/empty")" $'ROLLBACK_BEGIN\n\nROLLBACK_END'
assert_contains "empty pools survives as an environment entry" "$(cat "$WORK/empty")" $'POOLS_BEGIN\n\nPOOLS_END'
printf 'tok\nactor\n0123456789abcdef0123456789abcdef\nrb\npb\nmvk\ntvk\n' >"$WORK/truncated"
execute_launch "$WORK/truncated" "$WORK/missing" 2>/dev/null
assert_eq "a truncated stream refuses to launch" "$?" 1
base64() { return 9; }
capture_launch "$ROLLBACK" "$POOLS"
ENCODE_RC=$?
unset -f base64
assert_eq "an encoder failure refuses to launch" "$ENCODE_RC" 1
assert_eq "an encoder failure never reaches the remote launch" "$(if [ -s "$LAUNCH_FILE" ]; then echo 1; else echo 0; fi)" 0
assert_eq "an encoder failure records no durable launch intent" "$(if [ -e "$PREPARE_FILE" ]; then echo 1; else echo 0; fi)" 0

echo "selftest-e2e-forwarded-env: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
