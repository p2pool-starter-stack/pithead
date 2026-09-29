#!/usr/bin/env bash
# #2741: the #516 feed predicate matches the ceiling and keeps what the feed last showed for the failure row.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
REVERSE="$HERE/../lib/run-rig-reverse.sh"
for fn in _pred_feed_maxt _rig_direct_summary _reverse_feed_failure_detail; do
    SRC="$(sed -n "/^$fn() {/,/^}\$/p" "$REVERSE")"
    assert_contains "$fn is extractable" "$SRC" "$fn()"
    eval "$SRC"
done
REVERSE_SRC="$(sed -n '/^run_rigforge_reverse() {/,/^}$/p' "$REVERSE")"
# shellcheck disable=SC2016  # the literal call text
assert_contains "the #516 failure row uses the detail helper" "$REVERSE_SRC" '"$(_reverse_feed_failure_detail "$reflect")"'
# shellcheck disable=SC2034  # read by the eval'd production functions
RIG_HOST=rig IT_RIG_TOKEN=tok

echo "== #516 feed predicate keeps what the feed last showed (#2741) =="
FEED=""
api_state() { printf '%s' "$FEED"; }

FEED='{"workers":[{"name":"rig1","status":"online","rigforge":{"stats":[{"label":"Temp / max","value":"67°C / 102°C"}]}}]}'
_pred_feed_maxt rig1 102
assert_eq "the new ceiling satisfies the predicate" "$?" "0"

FEED='{"workers":[{"name":"rig1","status":"offline","rigforge":{"stats":[{"label":"Temp / max","value":"67°C / 100°C"}]}}]}'
_pred_feed_maxt rig1 102
assert_eq "the old ceiling does not" "$?" "1"
assert_eq "the old ceiling is kept for the failure row" "$_FEED_MAXT_SEEN" "status=offline, stats: Temp / max=67°C / 100°C"

FEED='{"workers":[{"name":"rig1","status":"online","rigforge":{"stats":[{"label":"Agent report","value":"stale for 2m"}]}}]}'
_pred_feed_maxt rig1 102
assert_eq "a stale report is named" "$_FEED_MAXT_SEEN" "status=online, stats: Agent report=stale for 2m"

FEED='{"workers":[{"name":"other"}]}'
_pred_feed_maxt rig1 102
assert_eq "a missing rig is named" "$_FEED_MAXT_SEEN" "rig not in the feed"

FEED=""
_pred_feed_maxt rig1 102
assert_eq "an empty /api/state replaces the previous poll's rows" "$_FEED_MAXT_SEEN" "no response from /api/state"

FEED='{"workers":[{"name":"rig1","status":"online","rigforge":{"stats":[{"label":"Governor","value":"performance"},{"label":"Temp / max","value":"67°C / 100°C"}]}}]}'
_pred_feed_maxt rig1 102
assert_eq "unrelated stats rows are not captured" "$_FEED_MAXT_SEEN" "status=online, stats: Temp / max=67°C / 100°C"
FEED='not json'
_pred_feed_maxt rig1 102
assert_eq "a malformed response is named" "$_FEED_MAXT_SEEN" "unparseable /api/state"

echo "== direct rig summary and the failure row's detail =="
RX_BODY='{"generated_at":"2026-09-26T10:00:00Z","rigforge":{"watchdog":{"max_temp_c":100}}}' RX_RC=0
rx() {
    cat >/dev/null
    printf '%s' "$RX_BODY"
    return "$RX_RC"
}
assert_eq "the direct read reports the stamp and ceiling" "$(_rig_direct_summary)" "generated_at=2026-09-26T10:00:00Z, watchdog max_temp_c=100"
RX_BODY='{}'
assert_eq "an absent stamp and ceiling are explicit" "$(_rig_direct_summary)" "generated_at=absent, watchdog max_temp_c=absent"
RX_BODY='oops'
assert_eq "an unparseable direct read is named" "$(_rig_direct_summary)" "direct /1/summary unparseable"
RX_RC=22
assert_eq "a failed direct read is named" "$(_rig_direct_summary)" "direct /1/summary read failed"
RX_BODY='{"generated_at":"2026-09-26T10:00:00Z","rigforge":{"watchdog":{"max_temp_c":100}}}' RX_RC=0
FEED='{"workers":[{"name":"rig1","status":"offline","rigforge":{"stats":[{"label":"Temp / max","value":"67°C / 100°C"}]}}]}'
_pred_feed_maxt rig1 102
assert_eq "the failure detail joins both views" "$(_reverse_feed_failure_detail 102)" \
    "feed never showed max_temp_c=102; last poll: status=offline, stats: Temp / max=67°C / 100°C; rig direct: generated_at=2026-09-26T10:00:00Z, watchdog max_temp_c=100"

printf '\nselftest-rigforge-feed-maxt: %s\n' "$([ "$IT_FAIL" -eq 0 ] && echo PASS || echo FAIL)"
[ "$IT_FAIL" -eq 0 ]
