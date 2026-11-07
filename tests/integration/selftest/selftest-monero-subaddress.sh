#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/../scenarios.sh"

echo "== monero subaddress: scenario prerequisites and resolved config =="
overrides="$(scenario_overrides local-pruned-main-subaddress || true)"
assert_contains "subaddress scenario is prerequisite gated" "$overrides" "monero_subaddress=env"
unset IT_MONERO_SUBADDRESS IT_MONERO_VIEW_KEY
if resolve_overrides "$overrides"; then
    it_fail "missing subaddress skips the row" "resolved without a subaddress"
else
    it_pass "missing subaddress skips the row"
fi
IT_MONERO_SUBADDRESS="$(printf '8%094d' 0)"
if resolve_overrides "$overrides"; then
    it_fail "missing view key skips the row" "resolved without a view key"
else
    it_pass "missing view key skips the row"
fi
IT_MONERO_VIEW_KEY="$(printf '%064d' 0)"
resolve_overrides "$overrides"
assert_contains "subaddress reaches the scenario config" "$RESOLVED" "monero.subaddress=$IT_MONERO_SUBADDRESS"
assert_contains "view key reaches the scenario config" "$RESOLVED" "monero.view_key=$IT_MONERO_VIEW_KEY"
case "$RESOLVED" in
*monero_subaddress=env*) it_fail "marker is removed" "marker remained" ;;
*) it_pass "marker is removed" ;;
esac
echo "== monero subaddress: redaction by name =="
probe="$(printf '%s' bounded-marker)"
for line in "MONERO_SUBADDRESS=$probe" "{\"subaddress\":\"$probe\"}" "--subaddress $probe" "--subaddress=$probe"; do
    case "$(printf '%s\n' "$line" | redact)" in
    *"$probe"*) it_fail "subaddress is redacted by name" "value survived" ;;
    *) it_pass "subaddress is redacted by name" ;;
    esac
done
[ "$IT_FAIL" -eq 0 ]
