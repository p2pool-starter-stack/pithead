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
# userspace. This is a genuine `bad`, not a special-cased pass: once #2187 lands real signing, the
# same check starts reaching userspace and flips green with no test-file change required.

# $1 = 1 if virt-install successfully defined+started the guest, 0/empty otherwise (e.g. no
#      matching OVMF secure-boot firmware on the host — an environment gap, not this appliance's)
# $2 = 1 if a userspace banner appeared on serial within the boot window, 0/empty otherwise
# Prints the verdict line on stdout; exit 0 = pass (boots under SB), 1 = fail (does not, or
# could not even be measured).
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
    echo "the image does NOT reach userspace with Secure Boot ON (pithead#2187: shim-signed is the only signed link in the chain — grub-efi-amd64 and the kernel ship unsigned) — this is the current, tracked state, not a battery defect; the row goes green the day #2187's signing lands"
    return 1
}
