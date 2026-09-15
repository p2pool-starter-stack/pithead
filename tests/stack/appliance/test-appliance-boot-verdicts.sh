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
# signals (did virt-install define the guest, did a userspace banner appear) — pulled into
# tests/os/secure-boot-boot-verdict.sh for exactly that reason. The case that matters is the
# second pair below: a guest that DEFINED successfully but never reached userspace records the
# signing gap (pithead#2187) without failing unrelated KVM evidence. #2187 defers signing past
# 2.0.0 to `v2.x - post-GA`; the same check reports signing works when that work lands.
# Mutation run: return failure for the measured deferred state -> this case flips from pass to
# fail, reintroducing the gate #2247 removes.
sbv() { # <virt-install-defined> <userspace-banner-seen> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/secure-boot-boot-verdict.sh"
        secure_boot_boot_verdict "$1" "$2"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "guest defined + reaches userspace under SB: passes" \
    "$(sbv 1 1)" \
    "0 the image reaches userspace with Secure Boot ON — signing works (or SB was not actually enforced; cross-check the guest's own SecureBoot EFI variable before trusting this as a pass)"
assert_eq "guest defined but never reaches userspace under SB: records today's deferred state" \
    "$(sbv 1 0)" \
    "0 the image does NOT reach userspace with Secure Boot ON (pithead#2187: shim-signed is the only signed link in the chain — grub-efi-amd64 and the kernel ship unsigned) — this is the measured, deferred state; signing is deferred past 2.0.0 to v2.x - post-GA"
assert_eq "virt-install could not even define the guest: fails, names it unmeasured (a possible bench firmware gap)" \
    "$(sbv 0 0)" \
    "1 could not even DEFINE a Secure-Boot-enabled guest (no matching OVMF secure-boot firmware on this host?) — Secure Boot is UNMEASURED here, not proven either way; check for a bench firmware gap before reading this as a product defect"
unset -f sbv
