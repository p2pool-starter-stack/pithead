#!/usr/bin/env bash
# #2741: the #516 feed predicate matches the ceiling and keeps what the feed last showed for the failure row.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
PRED_SRC="$(sed -n '/^_pred_feed_maxt() {/,/^}$/p' "$HERE/../lib/run-rig-reverse.sh")"
assert_contains "feed predicate is extractable" "$PRED_SRC" "_pred_feed_maxt()"
eval "$PRED_SRC"

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

printf '\nselftest-rigforge-feed-maxt: %s\n' "$([ "$IT_FAIL" -eq 0 ] && echo PASS || echo FAIL)"
[ "$IT_FAIL" -eq 0 ]
