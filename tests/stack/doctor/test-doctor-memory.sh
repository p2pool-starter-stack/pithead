# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Doctor's HugePages verdict (#2610). Any non-zero HugePages_Total used to read OK, and a bench
# said OK at 186 pages while P2Pool's RandomX dataset and its two caches need 1296. The verdict now
# holds the pool to this machine's budget (hugepages_decision_pages), never below P2Pool's 1296,
# and a shortfall is a WARN, never a FAIL: the appliance's A/B commit gate takes doctor's exit
# code. The appliance's degraded-marker WARN is test-appliance-identity-boot.sh's, not re-proven.
#
# Fixture meminfo through PITHEAD_MEMINFO, the overlay's override; PITHEAD_HUGEPAGES_MARKER points
# at a path that never exists unless a row writes it, so the host's /run cannot leak in. Sourced
# after test-doctor-surface.sh: the appliance wording runs through its _dr_leaks sweep.

echo "== unit: doctor's HugePages verdict holds the pool to the stack's budget (#2610) =="
MEMD="$SANDBOX/doctor-memory"
mkdir -p "$MEMD"
_meminfo() { printf 'MemTotal:       16318412 kB\nHugePages_Total:    %s\nHugePages_Free:     %s\n' "$1" "$2" >"$MEMD/meminfo"; }
_hp() { # appliance(0|1) -> check_hugepages_reserved's output
    PITHEAD_APPLIANCE="$1" PITHEAD_MEMINFO="$MEMD/meminfo" PITHEAD_HUGEPAGES_MARKER="$MEMD/marker" \
        run_sourced "$SANDBOX" check_hugepages_reserved 2>&1
}
rm -f "$MEMD/marker"

# The bench's pool: short of the budget AND of P2Pool's own pages.
_meminfo 186 186
out="$(_hp 0)"
assert_contains "186 pages: WARN" "$out" "⚠ WARN"
assert_not_contains "186 pages: never a FAIL" "$out" "FAIL"
assert_not_contains "186 pages: not OK" "$out" "✓ OK"
assert_contains "186 pages: names the shortfall against the budget" "$out" "only 186 of the 3072 pages"
assert_contains "186 pages: names the shortfall in MiB" "$out" "(5772 MiB short)"
assert_contains "186 pages: says P2Pool's pages do not fit" "$out" "too few for P2Pool's RandomX dataset and caches (1296 pages)"
assert_contains "186 pages: says what that does to P2Pool today" "$out" "exceeds its 1 GiB memory limit and restarts in a loop"
assert_contains "186 pages: names setup as the fix" "$out" "Run './pithead setup'"
assert_contains "186 pages: names the GRUB parameter that keeps it across reboots" "$out" "keep hugepages=3072 on the GRUB kernel command line"
assert_contains "186 pages: names the reboot for a pool setup cannot fill" "$out" "needs a reboot"

# The stack's full budget: OK, and the only verdict.
_meminfo 3072 1800
out="$(_hp 0)"
assert_contains "3072 pages: OK" "$out" "✓ OK   HugePages reserved: 3072 total, 1800 free"
assert_not_contains "3072 pages: no WARN" "$out" "WARN"

# P2Pool's boundary: 1295 cannot hold its pages, 1296 can but not beside a local monerod's.
_meminfo 1295 1295
out="$(_hp 0)"
assert_contains "1295 pages: P2Pool's pages do not fit" "$out" "too few for P2Pool's RandomX dataset"
_meminfo 1296 1296
out="$(_hp 0)"
assert_not_contains "1296 pages: P2Pool's pages alone fit" "$out" "too few for P2Pool's RandomX dataset"
assert_contains "1296 pages: both holders do not fit" "$out" "too few for both P2Pool's (1296 pages) and a local monerod's (1168 pages)"
_meminfo 2463 2463
out="$(_hp 0)"
assert_contains "2463 pages: both holders still do not fit" "$out" "too few for both"
_meminfo 2464 2464
out="$(_hp 0)"
assert_contains "2464 pages: both datasets fit, short of the budget's headroom: WARN" "$out" "Both RandomX datasets fit, without the headroom"
assert_not_contains "2464 pages: no crash-loop claim" "$out" "restarts in a loop"

# The appliance's reduced tier: its recorded pool IS the budget, so the full pool is not demanded.
printf 'reduced\npages=2560\n' >"$MEMD/marker"
_meminfo 2560 2560
out="$(_hp 1)"
assert_contains "reduced tier at its recorded 2560 pages: OK" "$out" "✓ OK"
_meminfo 1000 1000
out="$(_hp 1)"
assert_contains "reduced tier short of its recorded pool: WARN against 2560" "$out" "only 1000 of the 2560 pages"
assert_contains "appliance wording says no dashboard control reserves them" "$out" "There is no dashboard control that reserves them."
if declare -F _dr_leaks >/dev/null; then
    assert_eq "appliance wording names no CLI verb (_dr_leaks)" \
        "$(printf '    dr_warn "%s"\n' "$out" | _dr_leaks | grep -c . || true)" "0"
    # Control: the host wording of the same verdict must trip the sweep, or the 0 above is vacuous.
    assert_eq "control: the host wording trips _dr_leaks" \
        "$(printf '    dr_warn "%s"\n' "$(_hp 0)" | _dr_leaks | grep -c . || true)" "1"
else
    bad "appliance wording names no CLI verb (_dr_leaks)" "_dr_leaks is undefined: source test-doctor-surface.sh first"
fi

# The released tier (pages=0): no pool is the plan, so 0 keeps the zero WARN, but a pool that
# cannot hold P2Pool's pages is never OK.
printf 'released\npages=0\n' >"$MEMD/marker"
_meminfo 186 186
out="$(_hp 1)"
assert_contains "released tier at 186 pages: WARN against P2Pool's 1296" "$out" "only 186 of the 1296 pages"
_meminfo 0 0
out="$(_hp 1)"
assert_contains "released tier at 0 pages: the existing zero WARN" "$out" "HugePages_Total is 0"
rm -f "$MEMD/marker"

# The unchanged edges: no pool, and no HugePages line at all.
_meminfo 0 0
out="$(_hp 0)"
assert_contains "0 pages: the existing zero WARN" "$out" "HugePages_Total is 0"
printf 'MemTotal:       16318412 kB\n' >"$MEMD/meminfo"
out="$(_hp 0)"
assert_contains "no HugePages line: could-not-read WARN" "$out" "Could not read HugePages"

echo "== black-box: doctor's Memory section carries the HugePages verdict (#2610) =="
# The unit rows prove the check; this proves doctor runs it. Same fake daemon as test-doctor.sh's
# exit-code row, so doctor still exits 1 on that daemon's FAIL and the exit code says nothing here.
MDOC="$SANDBOX/doctor-memory-bb"
mkdir -p "$MDOC/bin"
cp "$STACK" "$MDOC/pithead"
printf '#!/usr/bin/env bash\ncase "$*" in info) exit 1 ;; *) exit 0 ;; esac\n' >"$MDOC/bin/docker"
printf '#!/usr/bin/env bash\nexit 0\n' >"$MDOC/bin/sudo"
chmod +x "$MDOC/bin/docker" "$MDOC/bin/sudo"
_meminfo 186 186
out="$(cd "$MDOC" && PITHEAD_APPLIANCE=0 PITHEAD_MEMINFO="$MEMD/meminfo" PITHEAD_HUGEPAGES_MARKER="$MEMD/marker" \
    PATH="$MDOC/bin:$PATH" ./pithead doctor 2>&1)"
assert_contains "doctor at 186 pages: WARN names the shortfall" "$out" "⚠ WARN HugePages reserved: only 186 of the 3072 pages"
assert_not_contains "doctor at 186 pages: no OK for the pool" "$out" "✓ OK   HugePages reserved"
