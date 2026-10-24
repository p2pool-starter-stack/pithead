# shellcheck shell=bash
# Exact versions only, so a non-boot after 2.0.1 fails instead of riding the #2187 deferral.
secure_boot_deferred() {
    [ "$1" = 2.0.0 ] || [ "$1" = 2.0.1 ]
}

secure_boot_boot_verdict() {
    local defined="$1" booted="$2" version="$3"
    if [ "$defined" != 1 ]; then
        echo "could not even DEFINE a Secure-Boot-enabled guest (no matching OVMF secure-boot firmware on this host?) — Secure Boot is UNMEASURED here, not proven either way; check for a bench firmware gap before reading this as a product defect"
        return 1
    fi
    if [ "$booted" = 1 ]; then
        echo "the image reaches userspace with Secure Boot ON — signing works (or SB was not actually enforced; cross-check the guest's own SecureBoot EFI variable before trusting this as a pass)"
        return 0
    fi
    if secure_boot_deferred "$version"; then
        echo "the image does NOT reach userspace with Secure Boot ON (pithead#2187: the firmware refuses the unsigned GRUB at EFI/BOOT/BOOTX64.EFI, and no signed shim is on the ESP) — measured, deferred through 2.0.1"
        return 0
    fi
    echo "the image does NOT reach userspace with Secure Boot ON — signing is required, so this is a regression"
    return 1
}
