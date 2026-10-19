#!/usr/bin/env bash
# Bounded/current-epoch controls for the p2pool -> Tari readiness observation (#3059).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/mergemine-probe.sh
source "$HERE/../lib/mergemine-probe.sh"

MM_CHAIN_ID=01f0cf665bd4cd31cbb2b2470236389c483522b350335e10a4a5dca34cb85990
MM_LOCAL='p2pool | MergeMiningClientTari worker thread ready'
MM_FULL="$MM_LOCAL
p2pool | MergeMiningClientTari tari://127.0.0.1:18142 uses chain_id $MM_CHAIN_ID"
MM_TMP="$(mktemp -d)"
trap 'rm -rf "$MM_TMP"' EXIT

mkdir "$MM_TMP/bin"
printf '%s\n' '#!/usr/bin/env bash' 'shift' 'exec "$@"' >"$MM_TMP/bin/timeout"
# shellcheck disable=SC2016 # literal fake-executable source
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$MM_FAKE_LOG"' 'exit "$MM_FAKE_RC"' >"$MM_TMP/bin/docker"
chmod +x "$MM_TMP/bin/timeout" "$MM_TMP/bin/docker"

echo "== the capture finds delayed success without unbounded transfer =="

MM_FAKE_LOG="$(for _ in $(seq 1 2100); do printf 'unrelated startup retry\n'; done)
$MM_FULL
$(for _ in $(seq 1 250); do printf '%s\n' "$MM_LOCAL"; done)
$(printf 'p2pool | MergeMiningClientTari %03000d\n' 0)"
MM_FAKE_RC=0
export MM_FAKE_LOG MM_FAKE_RC
rx() {
    local encoded="${1#bash -c }"
    eval "set -- $encoded"
    PATH="$MM_TMP/bin:$PATH" bash -c "$1"
}
capture="$(mm_capture_startup '2026-10-14T00:00:00Z')"
assert_contains "a chain_id after 2,000 noisy lines and before 250 later client lines is retained" \
    "$(mm_roundtrip_verdict "$capture")" "roundtrip $MM_CHAIN_ID"
MM_GOT_LINES="$(printf '%s\n' "$capture" | wc -l | tr -d ' ')"
if [ "$MM_GOT_LINES" -le $((MM_CAPTURE_LINES + 1)) ]; then it_pass "the target transfers only its bounded ring plus retained success"; else it_fail "the target transfers only its bounded ring plus retained success" "got $MM_GOT_LINES lines"; fi
MM_GOT_BYTES="$(printf '%s\n' "$capture" | awk '{if(length>m)m=length} END{print m+0}')"
if [ "$MM_GOT_BYTES" -eq "$MM_CAPTURE_LINE_BYTES" ]; then it_pass "the overlong matching line is clipped at the byte bound"; else it_fail "the overlong matching line is clipped at the byte bound" "expected $MM_CAPTURE_LINE_BYTES bytes, got $MM_GOT_BYTES"; fi

MM_FAKE_LOG="$MM_FULL"
MM_FAKE_RC=17
export MM_FAKE_LOG MM_FAKE_RC
mm_capture_startup '2026-10-14T00:00:00Z' >/dev/null 2>&1
assert_rc "the generated pipeline preserves a failed docker log status" "$?" "2"
unset -f rx

rx() { printf 'container-id|2026-10-14 01:02:03.4 +0000 UTC\n'; }
assert_eq "the epoch atomically binds container ID and normalized StartedAt" \
    "$(mm_epoch)" "container-id|2026-10-14T01:02:03.4+00:00"
rx() {
    printf 'stale-id|2026-10-14T01:02:03Z\n'
    return 17
}
mm_epoch >/dev/null 2>&1
assert_rc "a failed atomic epoch read is binding even if it emitted a tuple" "$?" "1"
unset -f rx

echo "== readiness polling is bounded and bound to one current container epoch =="

mm_script_next() { # <file>
    local value
    value="$(head -n 1 "$1")"
    tail -n +2 "$1" >"$1.next"
    mv "$1.next" "$1"
    printf '%s\n' "$value"
}
mm_observe_case() { # <epochs comma-list> <captures comma-list> <timeout>
    printf '%s' "$1" | tr ',' '\n' >"$MM_TMP/epochs"
    printf '%s' "$2" | tr ',' '\n' >"$MM_TMP/captures"
    printf '0\n' >"$MM_TMP/clock"
    (
        MM_READY_TIMEOUT="$3" MM_READY_INTERVAL=0
        mm_epoch() { mm_script_next "$MM_TMP/epochs"; }
        mm_capture_startup() {
            local token
            token="$(mm_script_next "$MM_TMP/captures")"
            case "$token" in
            FULL) printf '%s\n' "$MM_FULL" ;;
            LOCAL) printf '%s\n' "$MM_LOCAL" ;;
            EMPTY) ;;
            ERROR) return 2 ;;
            esac
        }
        now_s() {
            local n
            n="$(head -n 1 "$MM_TMP/clock")"
            printf '%s\n' $((n + 1)) >"$MM_TMP/clock"
            printf '%s\n' "$n"
        }
        sleep() { :; }
        local out rc=0
        out="$(mm_await_roundtrip)" || rc=$?
        printf '%s rc=%s\n' "$out" "$rc"
    )
}

assert_contains "a delayed chain_id passes inside the readiness deadline" \
    "$(mm_observe_case 'epoch-a,epoch-a,epoch-a' 'LOCAL,FULL' 3)" "roundtrip $MM_CHAIN_ID|epoch-a rc=0"
assert_eq "persistent local-only output exhausts the bound and fails" \
    "$(mm_observe_case 'epoch-a,epoch-a,epoch-a' 'LOCAL,LOCAL' 1)" "local-only|epoch-a rc=1"
assert_eq "persistent absent output exhausts the bound and fails" \
    "$(mm_observe_case 'epoch-a,epoch-a,epoch-a' 'EMPTY,EMPTY' 1)" "absent|epoch-a rc=1"
assert_eq "a log read error is binding and distinguishable" \
    "$(mm_observe_case 'epoch-a' 'ERROR' 3)" "read-error|epoch-a rc=2"
assert_eq "a restart rejects the old epoch's success and judges only the new epoch" \
    "$(mm_observe_case 'epoch-old,epoch-new,epoch-new' 'FULL,LOCAL' 2)" "local-only|epoch-new rc=1"
assert_eq "a restart on the deadline cannot turn an unread new epoch into an absent verdict" \
    "$(mm_observe_case 'epoch-old,epoch-new' 'FULL' 1)" "epoch-changed|epoch-new rc=1"
assert_contains "a restart can pass only after the new epoch produces its own chain_id" \
    "$(mm_observe_case 'epoch-old,epoch-new,epoch-new' 'FULL,FULL' 3)" "roundtrip $MM_CHAIN_ID|epoch-new rc=0"

mm_final_race_outcome() { # <verdict> <monero-rc>
    (
        MM_RACE_VERDICT="$1" MM_RACE_MONERO_RC="$2"
        mm_await_roundtrip() {
            printf '%s|epoch-old\n' "$MM_RACE_VERDICT"
            [ "${MM_RACE_VERDICT%% *}" = roundtrip ]
        }
        mm_epoch() { printf 'epoch-new\n'; }
        monero_caught_up() { return "$MM_RACE_MONERO_RC"; }
        mm_startup_lost() { return 1; }
        # shellcheck disable=SC2034 # harness counters consumed dynamically by assertion helpers
        IT_PASS=0 IT_FAIL=0 IT_SKIPPED_LEGS=0 IT_SKIPPED_BY_DESIGN=0 IT_SKIPPED_MISSING=0 IT_SKIPPED_NAMES=""
        assert_mergemine_roundtrip >/dev/null 2>&1
        printf '%s %s %s\n' "$IT_PASS" "$IT_FAIL" "$IT_SKIPPED_LEGS"
    )
}
assert_eq "a restart immediately before PASS rejects the stale success" \
    "$(mm_final_race_outcome "roundtrip $MM_CHAIN_ID" 0)" "0 1 0"
assert_eq "a restart during the prerequisite check rejects a stale absent skip" \
    "$(mm_final_race_outcome absent 1)" "0 1 0"

echo ""
echo "selftest-mergemine-readiness: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
