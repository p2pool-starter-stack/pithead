#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/mergemine-probe.sh
source "$HERE/../lib/mergemine-probe.sh"

MM_TMP="$(mktemp -d)"
trap 'rm -rf "$MM_TMP"' EXIT
mkdir "$MM_TMP/bin"
MM_START=2026-10-09T02:24:00.000000000Z
MM_OLDEST=2026-10-09T02:24:17.500000000Z
MM_STARTUP=""
MM_RECENT=""
MM_LOG_RC=0
MM_RECENT_RC=0
MM_MONERO_RC=0
MM_RESTART_STAGE=""
MM_CHAIN_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MM_LOCAL='p2pool | MergeMiningClientTari worker thread ready'
MM_ROUNDTRIP="p2pool | MergeMiningClientTari tari://<endpoint> uses chain_id $MM_CHAIN_ID"
MM_READY_TIMEOUT=0
MM_READY_INTERVAL=0
export MM_TMP MM_START MM_OLDEST MM_STARTUP MM_RECENT MM_LOG_RC MM_RECENT_RC MM_RESTART_STAGE MM_READY_TIMEOUT MM_READY_INTERVAL

printf '%s\n' '#!/usr/bin/env bash' 'shift' 'exec "$@"' >"$MM_TMP/bin/timeout"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "docker %s\n" "$*" >>"$MM_TMP/trace"' \
    'case "$1" in' \
    'inspect)' \
    '  suffix=' \
    '  [ ! -e "$MM_TMP/restarted" ] || suffix=-new' \
    '  case "$*" in' \
    '  *.Id*) printf "fixture-id%s|%s\n" "$suffix" "$MM_START" ;;' \
    '  *) printf "%s\n" "$MM_START" ;;' \
    '  esac' \
    '  ;;' \
    'logs)' \
    '  trap "exit 23" PIPE' \
    '  [ "$MM_RESTART_STAGE" != before ] || : >"$MM_TMP/restarted"' \
    '  if [ -n "$MM_OLDEST" ]; then' \
    '    printf "%s payload-that-must-not-cross\n" "$MM_OLDEST"' \
    '    for _ in $(seq 1 200); do printf "later retained line\n"; done' \
    '  fi' \
    '  : >"$MM_TMP/drained"' \
    '  exit "$MM_LOG_RC"' \
    '  ;;' \
    'compose)' \
    '  case " $* " in' \
    '  *" --since 60s "*)' \
    '    printf "%s\n" "$MM_RECENT"' \
    '    [ "$MM_RESTART_STAGE" != during ] || : >"$MM_TMP/restarted"' \
    '    exit "$MM_RECENT_RC"' \
    '    ;;' \
    '  *) printf "%s\n" "$MM_STARTUP" ;;' \
    '  esac' \
    '  ;;' \
    '*) exit 1 ;;' \
    'esac' >"$MM_TMP/bin/docker"
chmod +x "$MM_TMP/bin/timeout" "$MM_TMP/bin/docker"

rx() {
    printf '%s\n' "$1" >>"$MM_TMP/trace"
    PATH="$MM_TMP/bin:$PATH" bash -c "$1"
}

mm_set() {
    MM_OLDEST="$1"
    MM_LOG_RC="${2:-0}"
    export MM_OLDEST MM_LOG_RC
    rm -f "$MM_TMP/drained" "$MM_TMP/restarted"
    : >"$MM_TMP/trace"
}

mm_lost_rc() {
    mm_startup_lost "$MM_START" >/dev/null 2>&1
    printf '%s\n' "$?"
}

echo "== the oldest retained instant is read completely and compared conservatively =="

mm_set 2026-10-09T02:24:17.500000000Z
assert_rc "a normal delayed first line keeps startup evidence complete" "$(mm_lost_rc)" 1
assert_eq "the oldest-line reader drains the complete Docker stream" \
    "$(test -e "$MM_TMP/drained" && printf yes)" yes
assert_contains "the reader asks Docker for timestamps from the observed start" \
    "$(cat "$MM_TMP/trace")" "docker logs --timestamps --since"
case "$(cat "$MM_TMP/trace")" in
*head*) it_fail "the oldest-line reader does not terminate Docker early" "found a head cap" ;;
*) it_pass "the oldest-line reader does not terminate Docker early" ;;
esac

mm_set 2026-10-09T02:25:00.000000000Z
assert_rc "exactly 60 seconds keeps startup evidence complete" "$(mm_lost_rc)" 1
mm_set 2026-10-09T02:25:00.000000001Z
assert_rc "one nanosecond beyond 60 seconds reports likely loss" "$(mm_lost_rc)" 0
mm_set 2026-10-08T22:25:00.000000000-04:00
assert_rc "equivalent offsets compare as the same instant" "$(mm_lost_rc)" 1
mm_set 2026-10-09T01:24:00.000000000Z
assert_rc "an older retained timestamp cannot imply rotation" "$(mm_lost_rc)" 1
mm_set not-a-timestamp
assert_rc "a malformed retained timestamp cannot imply rotation" "$(mm_lost_rc)" 1
mm_set ""
assert_rc "an empty retained log cannot imply rotation" "$(mm_lost_rc)" 1
mm_set 2026-10-09T16:06:00.000000000Z 19
assert_rc "a failed log read cannot imply rotation despite valid output" "$(mm_lost_rc)" 1

mm_set 2026-10-09T16:06:00.000000000Z
MM_START=not-a-timestamp
export MM_START
assert_rc "an unknown startup timestamp cannot imply rotation" "$(mm_lost_rc)" 1
MM_START=2026-10-09T02:24:00.000000000Z
export MM_START

echo "== only current-epoch fresh round-trip evidence can recover rotated logs =="

monero_caught_up() { return "$MM_MONERO_RC"; }

mm_outcome() {
    (
        # shellcheck disable=SC2034 # harness counters are consumed dynamically by assertion helpers
        IT_PASS=0 IT_FAIL=0 IT_SKIPPED_LEGS=0 IT_SKIPPED_MISSING=0 IT_SKIPPED_BY_DESIGN=0 IT_SKIPPED_NAMES=""
        assert_mergemine_roundtrip 2>&1
        printf 'COUNTS %s %s %s %s %s\n' \
            "$IT_PASS" "$IT_FAIL" "$IT_SKIPPED_LEGS" "$IT_SKIPPED_MISSING" "$IT_SKIPPED_BY_DESIGN"
    )
}

mm_expect() {
    MM_OUTCOME="$(mm_outcome)"
    assert_contains "$1" "$MM_OUTCOME" "COUNTS $2"
}

mm_case() {
    mm_set "$1"
    MM_STARTUP="$2"
    MM_RECENT="$3"
    MM_RECENT_RC="${4:-0}"
    MM_RESTART_STAGE="${5:-}"
    MM_MONERO_RC=0
    export MM_STARTUP MM_RECENT MM_RECENT_RC MM_RESTART_STAGE
}

mm_case 2026-10-09T02:24:17.500000000Z "" ""
mm_expect "complete absent startup remains red" "0 1 0 0 0"
mm_case 2026-10-09T02:24:17.500000000Z "$MM_LOCAL" ""
mm_expect "complete local-only startup remains red" "0 1 0 0 0"
mm_case 2026-10-09T02:25:00.000000000Z "" ""
mm_expect "exactly 60 seconds leaves the full row red" "0 1 0 0 0"

mm_case 2026-10-09T16:06:00.000000000Z "" ""
mm_expect "rotated absent startup without fresh proof is missing" "0 0 1 1 0"
assert_contains "the missing reason states the greater-than-60-second heuristic" "$MM_OUTCOME" "more than 60 seconds"
assert_contains "the missing reason says startup evidence may be lost" "$MM_OUTCOME" "startup evidence"
MM_MONERO_RC=1
mm_expect "rotation loss outranks an unconfirmed Monero prerequisite" "0 0 1 1 0"
mm_case 2026-10-09T16:06:00.000000000Z "$MM_LOCAL" ""
mm_expect "rotated local-only startup without fresh proof is missing" "0 0 1 1 0"

mm_case 2026-10-09T16:06:00.000000000Z "" "$MM_ROUNDTRIP"
mm_expect "a fresh chain_id round-trip recovers rotated absent startup" "1 0 0 0 0"
assert_contains "the fallback captures a fresh window through the regular pipeline" \
    "$(cat "$MM_TMP/trace")" "--since 60s"
mm_case 2026-10-09T16:06:00.000000000Z "$MM_LOCAL" "$MM_ROUNDTRIP"
mm_expect "a fresh chain_id round-trip recovers rotated local-only startup" "1 0 0 0 0"
mm_case 2026-10-09T16:06:00.000000000Z "" "$MM_LOCAL"
mm_expect "a fresh local-only line cannot recover rotated startup" "0 0 1 1 0"

mm_case 2026-10-09T16:06:00.000000000Z "" "$MM_ROUNDTRIP" 17
mm_expect "a failed fresh read with valid payload cannot pass" "0 0 1 1 0"
mm_case 2026-10-09T16:06:00.000000000Z "" "$MM_ROUNDTRIP" 0 before
mm_expect "a replacement before the fresh capture refuses pass or skip" "0 1 0 0 0"
mm_case 2026-10-09T16:06:00.000000000Z "" "$MM_ROUNDTRIP" 0 during
mm_expect "a replacement during the fresh capture refuses pass or skip" "0 1 0 0 0"

mm_case not-a-timestamp "" ""
mm_expect "a malformed oldest timestamp leaves the original failure" "0 1 0 0 0"
mm_case "" "" ""
mm_expect "an empty oldest timestamp leaves the original failure" "0 1 0 0 0"
mm_case 2026-10-09T16:06:00.000000000Z "" ""
MM_LOG_RC=17
export MM_LOG_RC
mm_expect "an unreadable oldest log leaves the original failure" "0 1 0 0 0"

mm_case 2026-10-09T16:06:00.000000000Z "" ""
MM_START=not-a-timestamp
export MM_START
mm_expect "an unknown startup timestamp preserves the original failure" "0 1 0 0 0"
MM_MONERO_RC=1
mm_expect "an unknown startup timestamp preserves the original by-design skip" "0 0 1 0 1"
MM_START=2026-10-09T02:24:00.000000000Z
export MM_START

printf 'selftest-mergemine-rotation: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
