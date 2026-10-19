#!/usr/bin/env bash
#
# Self-test for #2668: rig-key-ledger.sh compacts an original where it is recorded, so a
# pretty-printed pools probe is one ledger entry rather than one per line, and refuses a value that
# is not one JSON value (warning by key, never the value) without arming the EXIT trap. The rest of
# the ledger is selftest-rig-key-ledger.sh; the callers' reaction to a refusal is
# selftest-rig-key-refusal.sh. Standalone, like those, so neither grows past its file-budget ceiling.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APPLY_LOG="$WORK/applies.log"
SCEN_OUT="$WORK/out.txt"
export INT_DIR="$HERE/.."
export APPLY_LOG WORK

# Each scenario is a fresh bash child, because an EXIT trap is only observable from outside the
# process it fires in. Restores are recorded to a FILE: a variable would lose writes made in $( ).
cat >"$WORK/prelude.sh" <<'PRELUDE'
set -uo pipefail
# shellcheck source=/dev/null
source "$INT_DIR/lib.sh"
# shellcheck source=/dev/null
source "$INT_DIR/lib/rig-key-ledger.sh"
_worker_apply() { printf 'dash|%s\n' "$2" >>"$APPLY_LOG"; }
_rig_control_apply() { printf 'rig|%s\n' "$1" >>"$APPLY_LOG"; }
PRELUDE

scenario() { # <body...> — run in a fresh child; output in SCEN_OUT, restore attempts in APPLY_LOG
    : >"$APPLY_LOG"
    : >"$SCEN_OUT"
    {
        cat "$WORK/prelude.sh"
        printf '%s\n' "$@"
    } >"$WORK/scen.sh"
    bash "$WORK/scen.sh" >"$SCEN_OUT" 2>&1
    printf '%s' "$?"
}

restores() { cat "$APPLY_LOG"; }
n_restores() { grep -c . "$APPLY_LOG"; }

echo "== a pretty-printed original is one ledger entry, not one per line (#2668) =="
# The shape an operator pastes into IT_RIG_POOLS_PROBE, which run_rigforge_pools seeds verbatim:
# newlines AND tab indentation, both of them the ledger's own delimiters. Stored raw, it split into
# five entries, restored nothing, and warned "restoring  on rig '"tabsecret"'".
scenario 'v=$'"'"'[\n\t{\n\t\t"url":\t"real:1",\n\t\t"pass":\t"tabsecret"\n\t}\n]'"'" \
    'rig_key_mark dash rig1 pools "$v"' 'echo "OUT=$(rig_key_outstanding)"' 'exit 1' >/dev/null
assert_eq "it is recorded as exactly one outstanding write (#2668)" "$(grep -c '^OUT=1$' "$SCEN_OUT")" "1"
assert_eq "and restored intact, compacted, credential and all (#2668)" \
    "$(restores)" 'dash|{"pools":[{"url":"real:1","pass":"tabsecret"}]}'
assert_eq "the unwind warns once, naming the pools key and the rig (#2668)" \
    "$(grep -c "restoring pools on rig 'rig1' via the dash route" "$SCEN_OUT")" "1"
assert_eq "and its pass is nowhere in the output (#2668)" "$(grep -c 'tabsecret' "$SCEN_OUT")" "0"

echo "== an original that is not one JSON value is refused at mark time, value unprinted (#2668) =="
scenario 'rig_key_mark dash rig1 pools "not-json-marksecret"; echo "MARK=$?"' \
    'rig_key_mark dash rig1 DONATION "5 6"; echo "MARK=$?"' 'echo "OUT=$(rig_key_outstanding)"' 'exit 1' >/dev/null
assert_eq "both marks return non-zero (#2668)" "$(grep -c '^MARK=1$' "$SCEN_OUT")" "2"
assert_eq "neither goes on the ledger (#2668)" "$(grep -c '^OUT=0$' "$SCEN_OUT")" "1"
assert_eq "each says, by key, that an abort will not restore it (#2668)" \
    "$(grep -c 'cannot record the original .* an abort will NOT restore it' "$SCEN_OUT")" "2"
assert_eq "the refused value is not printed (#2668)" "$(grep -c 'marksecret' "$SCEN_OUT")" "0"
assert_eq "and nothing is POSTed for it (#2668)" "$(n_restores)" "0"
# Nothing was recorded, so no EXIT trap should exist either; a valid mark afterwards still arms it.
scenario 'rig_key_mark dash rig1 pools "not-json"' 'echo "TRAP=[$(trap -p EXIT)]"' 'echo "OUT=$(rig_key_outstanding)"' \
    'rig_key_mark dash rig1 DONATION 0' 'echo "ARMED=$(trap -p EXIT | grep -c rig_key_atexit)"' 'exit 0' >/dev/null
assert_eq "a refused first mark installs no EXIT trap (#2668)" "$(grep -c '^TRAP=\[\]$' "$SCEN_OUT")" "1"
assert_eq "and records no entry (#2668)" "$(grep -c '^OUT=0$' "$SCEN_OUT")" "1"
assert_eq "a valid mark after a refused one still arms the trap (#2668)" "$(grep -c '^ARMED=1$' "$SCEN_OUT")" "1"

echo ""
echo "selftest-rig-key-compact: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
