# shellcheck shell=bash
#
# Shared by tests/os/phases/boot.sh's second guest (KVM, firmware.feature0.enabled=yes) and
# tests/stack/run.sh's fixture unit test: whether the appliance reaches userspace with Secure Boot
# ON, #2055 G2. Every virt-install in the battery runs with the feature explicitly `enabled=no`
# (#2055's own filing), so this was unmeasured — its only coverage was the manual hardware battery,
# which has never run (#2044). The image installs `shim-signed` (Microsoft-signed) but plain
# `grub-efi-amd64` and an unsigned kernel, with no sbsign/mokutil/enrolled-key tooling anywhere in
# the repo (filed as p2pool-starter-stack/pithead#2187), so the expected — and today CORRECT —
# verdict is that shim refuses to chainload the unsigned bootloader and the guest never reaches
# userspace. #2187 defers signing past 2.0.0 to `v2.x - post-GA`, so this known, measured state is
# recorded without failing unrelated KVM evidence. The same check reports signing works when a
# signed chain lands; a guest that cannot be defined remains a failure because it is unmeasured.

# $1 = 1 if virt-install successfully defined+started the guest, 0/empty otherwise (e.g. no
#      matching OVMF secure-boot firmware on the host — an environment gap, not this appliance's)
# $2 = 1 if a userspace banner appeared on serial within the boot window, 0/empty otherwise
# Prints the verdict line on stdout; exit 0 = measured (whether Secure Boot boots yet or is
# deferred), 1 = unmeasured.
secure_boot_boot_verdict() {
    local defined="$1" booted="$2"
    if [ "$defined" != 1 ]; then
        echo "could not even DEFINE a Secure-Boot-enabled guest (no matching OVMF secure-boot firmware on this host?) — Secure Boot is UNMEASURED here, not proven either way; check for a bench firmware gap before reading this as a product defect"
        return 1
    fi
    if [ "$booted" = 1 ]; then
        echo "the image reaches userspace with Secure Boot ON — signing works (or SB was not actually enforced; cross-check the guest's own SecureBoot EFI variable before trusting this as a pass)"
        return 0
    fi
    echo "the image does NOT reach userspace with Secure Boot ON (pithead#2187: shim-signed is the only signed link in the chain — grub-efi-amd64 and the kernel ship unsigned) — this is the measured, deferred state; signing is deferred past 2.0.0 to v2.x - post-GA"
    return 0
}
