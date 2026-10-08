# Re-generate the bootloader config after a /etc/default/grub edit and flag that a reboot is needed.
# Warns (rather than failing) when update-grub isn't on PATH so the user can run it by hand.
apply_grub_update() {
    if command -v update-grub >/dev/null; then
        sudo update-grub
        REBOOT_REQUIRED=true
    else
        warn "'update-grub' not found. Please manually update your bootloader."
    fi
}

# Self-heal an earlier release's typo: the THP-disable kernel param is singular
# (transparent_hugepage); the plural form is silently ignored, so THP was never disabled (#176).
# Rewrites the plural token to the singular form in grub file $1. Returns 0 if it changed something,
# 1 if there was nothing to heal — so callers only re-run update-grub when needed. Idempotent: a
# no-op once the file already uses the singular form.
heal_grub_thp_typo() {
    local grub="$1"
    grep -q "transparent_hugepages=" "$grub" || return 1
    sudo cp "$grub" "$grub.bak"
    sudo_sed 's/transparent_hugepages=/transparent_hugepage=/g' "$grub"
}

# Append the RandomX boot params to the active GRUB_CMDLINE_LINUX_DEFAULT="..." line in grub file $1,
# preserving any leading indentation. Returns 0 on success, 1 when there's no active double-quoted
# line to edit — commented out, single-quoted, or absent — so the caller can warn instead of
# silently running update-grub and claiming a reboot is needed. The leading-^ anchor also ensures a
# commented-out example line is never edited.
append_grub_boot_params() {
    local grub="$1"
    grep -q '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT="' "$grub" || return 1
    sudo cp "$grub" "$grub.bak"
    sudo_sed "s/^\([[:space:]]*\)GRUB_CMDLINE_LINUX_DEFAULT=\"/\1GRUB_CMDLINE_LINUX_DEFAULT=\"$(randomx_boot_params) /" "$grub"
}
