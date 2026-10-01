# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# run.sh's block layout (#2631): the audit that keeps every fragment in exactly one CI matrix leg,
# the argument check, and the full run that starts each block in its own process and sums them.
# Reads $SANDBOX and $ROOT from lib.sh and nothing a sibling domain assigns.

echo "== unit: run.sh's blocks hold every stanza once, and the matrix starts every block (#2631) =="
SB="$SANDBOX/suite-blocks"
mkdir -p "$SB"
SB_RUN="$ROOT/tests/stack/run.sh"
SB_WF="$ROOT/.github/workflows/shell.yml"
SB_N=$(sed -n 's/^STACK_BLOCKS=//p' "$SB_RUN")
out=$(stack_blocks_audit "$SB_RUN" "$SB_WF")
assert_rc "the shipped run.sh and shell.yml pass the block audit" "$?" "0"
assert_eq "...and the audit printed no defect" "$out" ""

# Each seeded copy breaks one rule, and the audit has to name it. A rule that stopped firing would
# leave the row above green over a layout that no longer puts every fragment in a leg.
sb_audit() { # <label> <expected-defect> <run.sh copy> [workflow copy]
    out=$(stack_blocks_audit "$3" "${4:-$SB_WF}" "$ROOT/tests/stack")
    assert_rc "$1 fails the audit" "$?" "1"
    assert_contains "$1 is named" "$out" "$2"
}
sb_stanza='_d0=$((PASS + FAIL)) && source "$HERE/test-harness-tooling.sh" && domain_ran test-harness-tooling.sh "$_d0" "$?" || domain_ran test-harness-tooling.sh "$_d0" "$?"'
{
    cat "$SB_RUN"
    printf '%s\n' "$sb_stanza"
} >"$SB/after-last.sh"
sb_audit "a stanza below the last block" "test-harness-tooling.sh is sourced outside every block" "$SB/after-last.sh"
{
    cat "$SB_RUN"
    printf 'assert_eq "inline" a a\n'
} >"$SB/inline.sh"
sb_audit "an assertion below the last block" "asserts outside every block" "$SB/inline.sh"
sb_first=$(grep -m1 'source "\$HERE/test-harness-tooling.sh"' "$SB_RUN")
awk -v s="$sb_first" '{ print } /^if in_block 2; then$/ { print s }' "$SB_RUN" >"$SB/twice.sh"
sb_audit "a stanza in two blocks" "test-harness-tooling.sh is sourced in block 1 and block 2" "$SB/twice.sh"
sed 's/^if in_block 3; then$/if in_block 2; then/' "$SB_RUN" >"$SB/order.sh"
sb_audit "a block numbered out of order" "block 2 is out of order: expected block 3" "$SB/order.sh"
sed "s/^\\( *block: \\[\\)[0-9, ]*\\]/\\1$(seq -s ', ' 1 $((SB_N - 1)))]/" "$SB_WF" >"$SB/shell.yml"
sb_audit "a matrix that skips a block" "matrix lists blocks [$(seq -s, 1 $((SB_N - 1)))], run.sh declares [$(seq -s, 1 "$SB_N")]" "$SB_RUN" "$SB/shell.yml"

sed '/source "\$HERE\/test-harness-tooling.sh"/d' "$SB_RUN" >"$SB/missing.sh"
sb_audit "a dropped stanza" "test-harness-tooling.sh is absent from every block" "$SB/missing.sh"
sed '/source "\$HERE\/test-harness-tooling.sh"/s/^/# /' "$SB_RUN" >"$SB/commented.sh"
sb_audit "a commented stanza" "test-harness-tooling.sh is absent from every block" "$SB/commented.sh"
sed '/source "\$HERE\/appliance\/test-appliance-boot-labels.sh"/c\    source "$HERE/appliance/test-appliance-boot-labels.sh"' "$SB_RUN" >"$SB/unaccounted.sh"
sb_audit "a bare boot-label source" "appliance/test-appliance-boot-labels.sh has no domain accounting" "$SB/unaccounted.sh"
for arg in 0 $((SB_N + 1)) x 1x 999999999999999999999999; do
    out=$(bash "$SB_RUN" "$arg" 2>&1)
    assert_rc "run.sh refuses block '$arg'" "$?" "2"
    assert_contains "run.sh names the block range for '$arg'" "$out" "BLOCK is 1..$SB_N"
done

echo "== unit: a full run starts each block in its own process and sums the verdicts (#2631) =="
# A miniature tree: the shipped run.sh head and tail around four one-line blocks, with its own
# four-leg matrix so the shipped block count does not matter. Block 1 leaves a variable that block 2
# asserts it cannot see; block 3 passes a row and then exits before its verdict, which the sum has
# to count as one failure instead of a block that contributed nothing. So the only right total is
# 2 passed (blocks 1 and 2), 2 failed (block 4's seeded failure and dead block 3).
SBT="$SB/tree"
mkdir -p "$SBT/tests/stack/lib" "$SBT/.github/workflows"
cp "$ROOT/tests/stack/lib.sh" "$SBT/tests/stack/"
cp "$ROOT/tests/stack/lib/config-read-sites.sh" "$SBT/tests/stack/lib/"
cp "$ROOT/tests/stack/lib/suite-blocks.sh" "$SBT/tests/stack/lib/"
printf 'jobs:\n  shell-block:\n    strategy:\n      matrix:\n        block: [1, 2, 3, 4]\n' >"$SBT/.github/workflows/shell.yml"
printf 'SB_LEAK=1\nok "block one"\n' >"$SBT/tests/stack/test-b1.sh"
printf 'assert_eq "block two cannot see block one'"'"'s variables" "${SB_LEAK:-}" ""\n' >"$SBT/tests/stack/test-b2.sh"
printf 'ok "block three"\nexit 1\n' >"$SBT/tests/stack/test-b3.sh"
printf 'bad "block four" "seeded failure"\n' >"$SBT/tests/stack/test-b4.sh"
{
    sed -n '1,/^STACK_BLOCK="\$1"$/p' "$SB_RUN" | sed 's/^STACK_BLOCKS=.*/STACK_BLOCKS=4/'
    printf 'in_block() { [ "$1" = "$STACK_BLOCK" ]; }\n'
    for sb_k in 1 2 3 4; do
        printf 'if in_block %s; then\n    _d0=$((PASS + FAIL)) && source "$HERE/test-b%s.sh" && domain_ran test-b%s.sh "$_d0" "$?" || domain_ran test-b%s.sh "$_d0" "$?"\nfi\n' "$sb_k" "$sb_k" "$sb_k" "$sb_k"
    done
    tail -2 "$SB_RUN"
} >"$SBT/tests/stack/run.sh"
out=$(bash "$SBT/tests/stack/run.sh" 2>&1)
assert_rc "a full run with a failed block exits 1" "$?" "1"
assert_contains "the full run sums the blocks, a dead one counted as a failure" "$out" \
    "pithead tests: "$'\033[1;32m'"2 passed"$'\033[0m'", "$'\033[1;31m'"2 failed"
assert_contains "the full run names the block that ended without a verdict" "$out" "block 3 ended without a verdict"
out=$(bash "$SBT/tests/stack/run.sh" 2 2>&1)
assert_rc "one block runs alone and carries its own verdict" "$?" "0"
assert_contains "a single block's summary names the block" "$out" "pithead tests, block 2 of 4:"
printf 'ok "block three"\n' >"$SBT/tests/stack/test-b3.sh"
printf 'ok "block four"\n' >"$SBT/tests/stack/test-b4.sh"
out=$(bash "$SBT/tests/stack/run.sh" 2>&1)
assert_rc "a full run with every block passing exits 0" "$?" "0"
assert_contains "the full run preserves every passing assertion" "$out" \
    "pithead tests: "$'\033[1;32m'"4 passed"$'\033[0m'", 0 failed"
printf 'ok "unlisted"\n' >"$SBT/tests/stack/test-unlisted.sh"
out=$(bash "$SBT/tests/stack/run.sh" 1 2>&1)
assert_rc "a new file missing from all blocks prevents execution" "$?" "2"
assert_contains "the missing file is named" "$out" "test-unlisted.sh is absent from every block"
rm -rf "$SB"
unset SB SB_RUN SB_WF SB_N SBT sb_stanza sb_first sb_k arg out
unset -f sb_audit
