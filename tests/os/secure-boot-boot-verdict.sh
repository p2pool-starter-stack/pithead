# shellcheck shell=bash

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
    echo "the image does NOT reach userspace with Secure Boot ON — Secure Boot is unsupported by design; turn it off"
    return 0
}
