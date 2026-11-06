#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
TMP="$(mktemp -d)" || exit 1
trap 'rm -r "$TMP"' EXIT

echo "== inventory succeeds without diagnostics on the unchanged tree =="
bash "$ROOT/tests/inventory.sh" >"$TMP/clean.out" 2>"$TMP/clean.err"
assert_rc "the real inventory exits zero" "$?" 0
assert_eq "the real inventory leaves stderr empty" "$(wc -c <"$TMP/clean.err" | tr -d '[:space:]')" 0

echo "== inventory counts and lists literal-tab scenarios only =="
mkdir -p "$TMP/tree/tests"
cp "$ROOT/tests/inventory.sh" "$TMP/tree/tests/inventory.sh"
ln -s "$ROOT/dashboard" "$TMP/tree/dashboard"
cp -R "$ROOT/tests/stack" "$ROOT/tests/integration" "$TMP/tree/tests/"
{
    printf "scenario_matrix() {\n    cat <<'EOF'\n"
    for n in {1..8}; do printf 'aaa-%s\tfoo=bar\n' "$n"; done
    printf '%s\n' 'lettert-only' 'literal\t-only' 'EOF' '}'
    sed -n '/^axis_coverage() {/,/^}/p' "$ROOT/tests/integration/scenarios.sh"
} >"$TMP/tree/tests/integration/scenarios.sh"

bash "$TMP/tree/tests/inventory.sh" >"$TMP/fixture.out" 2>"$TMP/fixture.err"
assert_rc "eight tab rows satisfy the scenario floor" "$?" 0
assert_eq "scenario enumeration leaves stderr empty" "$(wc -c <"$TMP/fixture.err" | tr -d '[:space:]')" 0
scenarios="$(sed -n '/^### Config scenarios /,/^### Axis coverage /p' "$TMP/fixture.out")"
assert_contains "the scenario total agrees with the listed rows" "$scenarios" '— 8'
for n in {1..8}; do
    assert_contains "tab row $n is listed" "$scenarios" "- aaa-$n"
done
assert_eq "letter t without a tab is excluded" "$(printf '%s\n' "$scenarios" | grep -Fc -- '- lettert-only')" 0
assert_eq "backslash t without a tab is excluded" "$(printf '%s\n' "$scenarios" | grep -Fc -- '- literal\t-only')" 0

printf '\n%d passed, %d failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
