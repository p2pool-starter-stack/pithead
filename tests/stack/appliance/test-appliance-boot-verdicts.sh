# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Two more boot verdicts split out of test-appliance-identity-boot.sh (#2055) rather than grown
# into it, to stay under its file-budget ceiling: same shape as the verdicts still there
# (hugepages_boot_verdict, restore_live_state_verdict, reinstall_prefill_verdict) — a simpler
# check could not tell two different histories apart, so the discrimination moved into a
# sourceable file the KVM battery and this fixture suite both drive. Ambient contract: $ROOT from
# lib.sh, plus lib.sh's assert_eq. Each verdict file is sourced for itself inside its own subshell.

echo "== unit: provisioning_ran_verdict — is-active alone can't tell skipped-by-design from never-triggered (#2055 G3) =="
# tests/os/run.sh's restore leg cannot be driven from here (it needs a real KVM guest), but the
# verdict is pure text-matching over four already-observed strings (two ActiveState reads, two
# ConditionResult reads) — pulled into tests/os/provisioning-settled.sh for exactly that reason,
# the same discrimination #1212 needed for hugepages. The case that matters is the second pair
# below: firstboot and boot BOTH read `inactive` (the exact "units: inactive inactive" row #2055
# names) but now fails instead of reading as a finished provisioning, because neither unit's
# ConditionResult says it ran.
# Mutation run: drop the ConditionResult check and fall back to judging ActiveState alone -> the
# "neither unit ran" case flips from fail to pass, silently reintroducing the #2055 G3 gap.
prv() { # <firstboot-active> <boot-active> <firstboot-ran> <boot-ran> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/provisioning-settled.sh"
        provisioning_ran_verdict "$1" "$2" "$3" "$4"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "firstboot skipped, boot ran (the normal provisioned case): passes" \
    "$(prv inactive active no yes)" \
    "0 one provisioning unit ran this boot (firstboot: inactive/ran=no, boot: active/ran=yes)"
assert_eq "firstboot ran, boot skipped (the normal unprovisioned case): passes" \
    "$(prv inactive inactive yes no)" \
    "0 one provisioning unit ran this boot (firstboot: inactive/ran=yes, boot: inactive/ran=no)"
assert_eq "both inactive, neither ran: fails — the #2055 G3 case is-active alone missed" \
    "$(prv inactive inactive no no)" \
    "1 neither provisioning unit ran this boot (firstboot ConditionResult: no, boot: no) — is-active alone cannot tell a correctly-skipped unit from one that never got the chance"
assert_eq "unreadable ConditionResult: fails, names it unreadable" \
    "$(prv inactive inactive "" "")" \
    "1 neither provisioning unit ran this boot (firstboot ConditionResult: unreadable, boot: unreadable) — is-active alone cannot tell a correctly-skipped unit from one that never got the chance"
unset -f prv

echo "== unit: secure_boot_boot_verdict — Secure Boot ON is measured, not left an unread flag (#2055 G2) =="
# tests/os/run.sh's phase_boot second guest cannot be driven from here (it needs real KVM +
# OVMF secure-boot firmware), but the verdict is pure text-matching over two already-observed
# signals (did virt-install define the guest, did a userspace banner appear, and image version) —
# pulled into
# tests/os/secure-boot-boot-verdict.sh for exactly that reason. The case that matters is the
# second pair below: a guest that DEFINED successfully but never reached userspace reports the
# signing gap without failing the phase for 2.0.0. Later versions require signing, so the same
# measured non-boot fails and the deferral cannot hide a regression.
sbv() { # <virt-install-defined> <userspace-banner-seen> <image-version> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/secure-boot-boot-verdict.sh"
        secure_boot_boot_verdict "$1" "$2" "$3"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "guest defined + reaches userspace under SB: passes" \
    "$(sbv 1 1 2.0.0)" \
    "0 the image reaches userspace with Secure Boot ON — signing works (or SB was not actually enforced; cross-check the guest's own SecureBoot EFI variable before trusting this as a pass)"
assert_eq "guest defined but never reaches userspace under SB: records the deferred state" \
    "$(sbv 1 0 2.0.0)" \
    "0 the image does NOT reach userspace with Secure Boot ON (pithead#2187: shim-signed is the only signed link in the chain — grub-efi-amd64 and the kernel ship unsigned) — measured, deferred past 2.0.0 to v2.x - post-GA"
assert_eq "guest defined but never reaches userspace after signing is required: fails" \
    "$(sbv 1 0 2.0.1)" \
    "1 the image does NOT reach userspace with Secure Boot ON — signing is required, so this is a regression"
assert_eq "virt-install could not even define the guest: fails, names it unmeasured (a possible bench firmware gap)" \
    "$(sbv 0 0 2.0.0)" \
    "1 could not even DEFINE a Secure-Boot-enabled guest (no matching OVMF secure-boot firmware on this host?) — Secure Boot is UNMEASURED here, not proven either way; check for a bench firmware gap before reading this as a product defect"
unset -f sbv

echo "== unit: fault_boot_verdict — BRICKED only when the serial shows no GRUB, kernel or login (#2381) =="
# bench-ci job 101's fault phase reported A1 as BRICKED (disqualifying) while its own
# pithead-os-serial.log.failed showed GRUB naming the current slot and "pithead login:" ten
# seconds later — the SSH probe failed, not the boot. tests/os/fault-boot-verdict.sh reads the
# serial console from the byte offset the power cycle started at and tells the two apart.
# Mutation run: drop the offset and let it scan the whole log -> the earlier boot's own GRUB/login
# lines "prove" a boot that never happened after THIS power cut, silently hiding a real brick.
FBV="$SANDBOX/fault-boot-verdict"
mkdir -p "$FBV"
# shellcheck source=tests/os/fault-boot-verdict.sh
source "$ROOT/tests/os/fault-boot-verdict.sh"
printf 'GNU GRUB  version 2.06\nLoading Linux 6.1.0 ...\nDebian GNU/Linux 12 pithead ttyS0\npithead login: ' \
    >"$FBV/booted"
verdict=$(fault_boot_verdict "$FBV/booted" 0)
assert_rc "a serial log naming GRUB, kernel and login is not BRICKED" "$?" "0"
assert_contains "…and says the probe failed, not the boot" "$verdict" "the PROBE failed to reach it, not the boot"
printf 'Powering up......\nqemu: no console output\n' >"$FBV/no-boot"
verdict=$(fault_boot_verdict "$FBV/no-boot" 0)
assert_rc "a serial log with no GRUB, kernel or login evidence IS BRICKED" "$?" "1"
assert_contains "…and quotes the serial's last lines" "$verdict" "qemu: no console output"
# The earlier boot's login line must not leak across the offset: a fresh power cycle appends to
# the SAME $SERIAL file rather than truncating it, so only bytes written after the mark count.
cat "$FBV/booted" "$FBV/no-boot" >"$FBV/combined"
mark=$(wc -c <"$FBV/booted" | tr -d ' ')
verdict=$(fault_boot_verdict "$FBV/combined" "$mark")
assert_rc "an earlier boot's login prompt does not mask a real brick after the offset" "$?" "1"
unset -f fault_boot_verdict
rm -rf "$FBV"

echo "== unit: m10_height_verdict — a readable lower height is chain loss, apart from an unreadable RPC (#2557) =="
# bench-ci job 840 failed M10.1 with "before: 56540, after: 56040" under one message that also
# covered an unreadable RPC. The leg now flushes the guest after the pre-cut read, so the verdict
# can hold the node to that persisted height and name which of the two failures it saw.
# Mutation run: drop the lower-height branch -> job 840's readable 56040 passes as a recovery.
mhv() { # <persisted-before> <after> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/m10-height-verdict.sh"
        m10_height_verdict "$1" "$2"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "job 840's readable lower height fails as lost persisted blocks" \
    "$(mhv 56540 56040)" \
    "1 monerod LOST 500 persisted blocks across the cut (persisted before: 56540, after: 56040)"
assert_eq "an unreadable post-cut RPC fails as unreadable, not as chain loss" \
    "$(mhv 56540 "")" \
    "1 monerod RPC unreadable after the cut (persisted before: 56540, after: unreadable)"
assert_eq "an unreadable pre-cut height fails before any comparison" \
    "$(mhv "" 56540)" \
    "1 could not read a persisted monerod height before the cut (read: unreadable)"
assert_eq "the same height passes" \
    "$(mhv 56540 56540)" \
    "0 monerod reports height 56540, at or past the persisted pre-cut height 56540"
assert_eq "a higher height passes" \
    "$(mhv 56540 56600)" \
    "0 monerod reports height 56600, at or past the persisted pre-cut height 56540"
unset -f mhv
