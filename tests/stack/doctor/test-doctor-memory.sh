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
assert_contains "186 pages: says P2Pool's dataset does not fit" "$out" "too few for P2Pool's RandomX dataset: P2Pool builds its RandomX dataset (1040 pages) in ordinary RAM"
assert_contains "186 pages: says what that does to P2Pool today" "$out" "exceeds its 1 GiB memory limit and restarts in a loop"
assert_contains "186 pages: names setup as the fix" "$out" "Run './pithead setup'"
assert_contains "186 pages: names the full boot parameters for GRUB" "$out" "put 'hugepagesz=2M hugepages=3072 transparent_hugepage=never' on GRUB_CMDLINE_LINUX_DEFAULT"
assert_contains "186 pages: says to replace a stale hugepages= value" "$out" "in place of any other hugepages= value"
assert_contains "186 pages: names update-grub and the reboot" "$out" "run 'sudo update-grub' and reboot"

# The stack's full budget: OK, and the only verdict.
_meminfo 3072 1800
out="$(_hp 0)"
assert_contains "3072 pages: OK" "$out" "✓ OK   HugePages reserved: 3072 total, 1800 free"
assert_not_contains "3072 pages: no WARN" "$out" "WARN"

# P2Pool's boundaries: below its 1040-page dataset P2Pool crash-loops under its 1 GiB limit whatever
# else holds pages. From 1040 to 1295 the dataset fits only if P2Pool allocates before monerod's two
# RandomX caches (up to 256 pages; monerod builds no dataset unless it mines), so the crash loop is
# named as conditional. From 1296 it fits either way, but below the budget it still WARNs.
_meminfo 1039 1039
out="$(_hp 0)"
assert_contains "1039 pages: WARN" "$out" "⚠ WARN"
assert_not_contains "1039 pages: never a FAIL" "$out" "FAIL"
assert_contains "1039 pages: P2Pool's dataset does not fit" "$out" "too few for P2Pool's RandomX dataset"
_meminfo 1040 1040
out="$(_hp 0)"
assert_contains "1040 pages: WARN, short of the budget" "$out" "⚠ WARN HugePages reserved: only 1040 of the 3072 pages"
assert_not_contains "1040 pages: never a FAIL" "$out" "FAIL"
assert_not_contains "1040 pages: no certain crash-loop claim" "$out" "too few for P2Pool's RandomX dataset"
assert_contains "1040 pages: the crash loop hangs on who allocates first" "$out" "P2Pool's RandomX dataset fits only if P2Pool takes its pages before monerod's RandomX caches do; if not, P2Pool builds its RandomX dataset (1040 pages) in ordinary RAM, exceeds its 1 GiB memory limit and restarts in a loop."
_meminfo 1295 1295
out="$(_hp 0)"
assert_contains "1295 pages: WARN, the crash loop still conditional" "$out" "⚠ WARN HugePages reserved: only 1295 of the 3072 pages this machine needs for RandomX (3554 MiB short). P2Pool's RandomX dataset fits only if"
_meminfo 1296 1296
out="$(_hp 0)"
assert_contains "1296 pages: WARN, short of the budget" "$out" "⚠ WARN HugePages reserved: only 1296 of the 3072 pages"
assert_not_contains "1296 pages: never a FAIL" "$out" "FAIL"
assert_not_contains "1296 pages: no crash-loop claim (the dataset fits beside monerod's caches)" "$out" "restarts in a loop"
assert_contains "1296 pages: says what does not fit falls back" "$out" "RandomX data that does not fit falls back to ordinary RAM."
_meminfo 3071 3071
out="$(_hp 0)"
assert_contains "3071 pages: one page short of the budget is a WARN" "$out" "⚠ WARN HugePages reserved: only 3071 of the 3072 pages"
assert_not_contains "3071 pages: never a FAIL" "$out" "FAIL"

# The appliance's reduced tier: its recorded pool IS the budget, so the full pool is not demanded.
printf 'reduced\npages=2560\n' >"$MEMD/marker"
_meminfo 2560 2560
out="$(_hp 1)"
assert_contains "reduced tier at its recorded 2560 pages: OK" "$out" "✓ OK"
_meminfo 1000 1000
out="$(_hp 1)"
assert_contains "reduced tier short of its recorded pool: WARN against 2560" "$out" "⚠ WARN HugePages reserved: only 1000 of the 2560 pages"
assert_not_contains "reduced tier short of its recorded pool: never a FAIL (the commit gate)" "$out" "FAIL"
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
assert_contains "released tier at 186 pages: WARN against P2Pool's 1296, labelled as its dataset and caches" "$out" "⚠ WARN HugePages reserved: only 186 of the 1296 pages P2Pool's RandomX dataset and its two caches need (2220 MiB short)."
assert_not_contains "released tier at 186 pages: never a FAIL (the commit gate)" "$out" "FAIL"
_meminfo 1295 1295
out="$(_hp 1)"
assert_contains "released tier at 1295 pages: one short of P2Pool's 1296 is a WARN" "$out" "⚠ WARN HugePages reserved: only 1295 of the 1296 pages"
assert_not_contains "released tier at 1295 pages: never a FAIL (the commit gate)" "$out" "FAIL"
_meminfo 1296 1296
out="$(_hp 1)"
assert_contains "released tier at 1296 pages: holds P2Pool's 1296, the whole target: OK" "$out" "✓ OK   HugePages reserved: 1296 total"
_meminfo 0 0
out="$(_hp 1)"
assert_contains "released tier at 0 pages: the zero WARN" "$out" "⚠ WARN HugePages_Total is 0"
assert_not_contains "released tier at 0 pages: never a FAIL (the commit gate)" "$out" "FAIL"
rm -f "$MEMD/marker"

# The unchanged edges: no pool, and no HugePages line at all.
_meminfo 0 0
out="$(_hp 0)"
assert_contains "0 pages: WARN names the crash loop, not a slowdown" "$out" "⚠ WARN HugePages_Total is 0: P2Pool builds its RandomX dataset (1040 pages) in ordinary RAM, exceeds its 1 GiB memory limit and restarts in a loop."
assert_not_contains "0 pages: no 'slower' wording" "$out" "slower"
assert_contains "0 pages: names setup as the fix" "$out" "Run './pithead setup'"
assert_not_contains "0 pages: never a FAIL" "$out" "FAIL"
printf 'MemTotal:       16318412 kB\n' >"$MEMD/meminfo"
out="$(_hp 0)"
assert_contains "no HugePages line: could-not-read WARN" "$out" "⚠ WARN Could not read HugePages"
assert_not_contains "no HugePages line: never a FAIL" "$out" "FAIL"
printf 'HugePages_Total:    n/a\n' >"$MEMD/meminfo"
out="$(_hp 0)"
assert_contains "non-numeric HugePages_Total: could-not-read WARN, not a zero pool" "$out" "⚠ WARN Could not read HugePages"
assert_not_contains "non-numeric HugePages_Total: never a FAIL" "$out" "FAIL"

# The crash-loop wording names P2Pool's memory limit as 1 GiB. Read the limit off both places it
# is set, so the change that moves it (#2609) reds here and rewrites the wording with it.
assert_eq "the wording's 1 GiB is P2Pool's compose mem_limit" \
    "$(awk '/^  p2pool:$/{f=1;next} f&&/^  [a-z]/{exit} f&&/^    mem_limit:/{print $2}' "$ROOT/docker-compose.yml")" "1g"
assert_eq "the wording's 1 GiB is P2Pool's quadlet --memory" \
    "$(awk '/^Image=\$reg\/pithead-p2pool:/{f=1} f&&/^PodmanArgs=--memory /{print $2; exit}' "$ROOT/lib/pithead/36-quadlet-units.sh")" "1g"

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
