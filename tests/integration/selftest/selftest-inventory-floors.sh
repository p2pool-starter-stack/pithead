#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
GATE="$ROOT/tests/inventory.sh"

echo "== inventory floor clean-tree control =="
rc=0
bash "$GATE" >"$TEST_DIR/control.out" 2>"$TEST_DIR/control.err" || rc=$?
assert_rc "real inventory passes" "$rc" 0
assert_eq "real inventory has no errors" "$(cat "$TEST_DIR/control.err")" ''

echo "== every inventory counter rejects a count below its floor =="
pairs=$(sed -n 's/^for pair in \(.*\); do$/\1/p' "$GATE")
expected='n_py_dash n_py_fake n_node n_stack n_selftest n_scen n_axes n_mini'
names=$(printf '%s\n' "$pairs" | tr ' ' '\n' | cut -d: -f1 | paste -sd ' ' -)
assert_eq "floor list covers every fixture" "$names" "$expected"
[ "$names" = "$expected" ] || exit 1
for pair in $pairs; do
    floor=${pair#*:}
    if ! [[ "$floor" =~ ^[0-9]+$ ]] || [ "$floor" -le 0 ]; then
        it_fail "${pair%%:*} has a positive floor" "$pair"
        exit 1
    fi
done

mkdir -p "$TEST_DIR/tree/tests" "$TEST_DIR/tree/dashboard/tests/frontend" \
    "$TEST_DIR/tree/tests/integration/fakes" "$TEST_DIR/tree/tests/stack" \
    "$TEST_DIR/tree/tests/integration/selftest" "$TEST_DIR/tree/tests/integration/mini-stack"
cp "$GATE" "$TEST_DIR/tree/tests/inventory.sh"
for target in $pairs; do
    counter=${target%%:*}
    floor=${target#*:}
    low=$((floor - 1))
    for pair in $pairs; do
        name=${pair%%:*}
        n=${pair#*:}
        [ "$name" != "$counter" ] || n=$low
        case "$name" in
        n_py_dash | n_py_fake)
            path=dashboard/tests/test_fixture.py
            [ "$name" != n_py_fake ] || path=tests/integration/fakes/test_fixture.py
            awk -v n="$n" 'BEGIN { for (i=0; i<n; i++) print "def test_" i "(): pass" }' >"$TEST_DIR/tree/$path"
            ;;
        n_node)
            awk -v n="$n" 'BEGIN { for (i=0; i<n; i++) print "test(\047case " i "\047, () => {});" }' >"$TEST_DIR/tree/dashboard/tests/frontend/fixture.test.mjs"
            ;;
        n_stack | n_selftest)
            path=tests/stack/sections.sh
            [ "$name" != n_selftest ] || path=tests/integration/selftest/sections.sh
            awk -v n="$n" 'BEGIN { for (i=0; i<n; i++) print "echo \"== section " i " ==\"" }' >"$TEST_DIR/tree/$path"
            ;;
        n_scen)
            awk -v n="$n" 'BEGIN { print "scenario_matrix() {"; for (i=0; i<n; i++) print "case" i "\tfixture"; print "EOF" }' >"$TEST_DIR/tree/tests/integration/scenarios.sh"
            ;;
        n_axes)
            awk -v n="$n" 'BEGIN { print "axis_coverage() {"; for (i=0; i<n; i++) print "axis" i "=fixture"; print "EOF" }' >>"$TEST_DIR/tree/tests/integration/scenarios.sh"
            ;;
        n_mini)
            awk -v n="$n" 'BEGIN { for (i=0; i<n; i++) print "log \"scenario " i "\"" }' >"$TEST_DIR/tree/tests/integration/mini-stack/run-mini-stack.sh"
            ;;
        esac
    done
    rc=0
    bash "$TEST_DIR/tree/tests/inventory.sh" >"$TEST_DIR/seed.out" 2>"$TEST_DIR/seed.err" || rc=$?
    assert_rc "$counter rejects floor minus one" "$rc" 1
    assert_contains "$counter names its count and floor" "$(cat "$TEST_DIR/seed.err")" \
        "inventory drift: $counter counted $low, floor $floor"
done

echo "selftest-inventory-floors: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
