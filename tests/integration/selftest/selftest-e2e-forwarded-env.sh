#!/usr/bin/env bash
# Execute e2e.sh's real detached-launch transport without a bench.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
contains() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac }
HARNESS_SRC="$(sed -n '/^run_harness() {$/,/^}$/p' "$HERE/../e2e.sh")"
assert_eq "the extraction is the whole run_harness function" \
    "$(printf '%s\n' "$HARNESS_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "run_harness() { } "

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LAUNCH_FILE="$WORK/launch" STDIN_FILE="$WORK/stdin" PREPARE_FILE="$WORK/prepare"

capture_launch() { # <rollback> <pools>
    : >"$LAUNCH_FILE"
    : >"$STDIN_FILE"
    rm -f "$PREPARE_FILE"
    (
        # shellcheck disable=SC2034 # read by the eval'd real run_harness
        MODE=matrix BORROW_MINER=0 WORKERS=1 BENCH_HOST=bench E2E_DIR=/srv/code/pithead-e2e SCENARIO=""
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
    CAPTURE_FILE="$2" bash -c '
        rm() { :; }; cd() { :; }
        grep() { test -s "$CAPTURE_FILE"; }
        nohup() {
            printf "ROLLBACK_BEGIN\n%s\nROLLBACK_END\nPOOLS_BEGIN\n%s\nPOOLS_END\nARGV[%s]\n" \
                "$IT_RIG_ROLLBACK_CHANGES" "$IT_RIG_POOLS_PROBE" "$*" >"$CAPTURE_FILE"
        }
        eval "$1"
    ' _ "$(cat "$LAUNCH_FILE")" <"$1" >/dev/null
}

echo "== exact five-record transport, multiline decode, environment, and argv hygiene =="
ROLLBACK=$'{"pools":[\n{"url":"127.0.0.1:1"}]}' POOLS='[{"url":"probe:1"}]'
capture_launch "$ROLLBACK" "$POOLS"
assert_eq "the producer emits exactly five records" "$(awk 'END {print NR}' "$STDIN_FILE")" 5
EXPECTED="$(printf 'tok\nactor\n0123456789abcdef0123456789abcdef\n%s\n%s' \
    'eyJwb29scyI6Wwp7InVybCI6IjEyNy4wLjAuMToxIn1dfQ==' 'W3sidXJsIjoicHJvYmU6MSJ9XQ==')"
assert_eq "record values and order are exact" "$(cat "$STDIN_FILE")" "$EXPECTED"
execute_launch "$STDIN_FILE" "$WORK/captured"
CAPTURED="$(cat "$WORK/captured")" ARGV="$(sed -n 's/^ARGV\[\(.*\)\]$/\1/p' "$WORK/captured")"
assert_contains "multiline rollback input reaches the runner environment intact" "$CAPTURED" "$(printf 'ROLLBACK_BEGIN\n%s\nROLLBACK_END' "$ROLLBACK")"
assert_contains "pools input reaches the runner environment intact" "$CAPTURED" "$(printf 'POOLS_BEGIN\n%s\nPOOLS_END' "$POOLS")"
assert_eq "rollback input stays out of runner argv" "$(contains "$ARGV" "$ROLLBACK")" no
assert_eq "pools input stays out of runner argv" "$(contains "$ARGV" "$POOLS")" no

echo "== empty values remain supplied, while missing records and encoder errors fail closed =="
capture_launch "" ""
execute_launch "$STDIN_FILE" "$WORK/empty"
assert_contains "empty rollback survives as an environment entry" "$(cat "$WORK/empty")" $'ROLLBACK_BEGIN\n\nROLLBACK_END'
assert_contains "empty pools survives as an environment entry" "$(cat "$WORK/empty")" $'POOLS_BEGIN\n\nPOOLS_END'
printf 'tok\nactor\n0123456789abcdef0123456789abcdef\n' >"$WORK/truncated"
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
