# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# #2352: a fresh USB install left both RAUC slots reading `bad` on a physical box, and
# pithead-boot's health-gated commit never ran on the disk's first provisioned boot. mkimage.sh's
# grubenv seed is asserted for the IMAGE in verify-image.sh; pithead-install's copy of that seed
# onto the INSTALLED disk had never been checked at all. Runs right after _phase_install_initial,
# on the same guest, so $ip and the SSH connection it left are still good.
#
# Boot 1 (the reboot into the disk that install-initial.sh already drove) CANNOT end committed:
# pithead-boot.service's ConditionPathExists needs config.json, and config.json does not exist
# until pithead-firstboot writes it — on THIS boot, as part of consuming the staged preseed. The
# two units are mutually exclusive by construction (provisioning-settled.sh), so a headless
# install's first boot is always firstboot's, never pithead-boot's; the commit is necessarily
# deferred to the NEXT boot. That handoff is exactly what this leg measures: does pithead-boot
# actually run and commit once config.json exists, or does the slot stay stuck the way the field
# report found it (both slots `bad`, "Activated: none")?
#
# grubenv's A_TRY=0 is NOT proof of a commit by itself: GRUB's own "nothing selectable" branch
# (grub.cfg) clears a stale A_TRY back to 0 on EVERY boot where no slot is currently selectable,
# committed or not — GRUB does this at bootloader time, before the OS or RAUC ever runs. The only
# signal that actually distinguishes "RAUC committed this slot" from "GRUB fell back to its
# hardcoded default" is `rauc status` itself resolving a primary slot (`Activated: rootfs.N`, not
# `none`) — that field comes from RAUC re-deriving the selection at report time, the same
# `Failed getting primary slot: ... No bootable slot found` warning path the field report hit.
_read_genv() { _ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' '; }
_genv_field() { printf '%s' "$1" | grep -oE "(^| )$2=[^ ]*" | tail -1 | cut -d= -f2; }        # <genv> <KEY>
_rauc_status() { _ssh "rauc status 2>&1" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g'; } # ANSI-stripped
_assert_rauc_committed() {                                                                    # <label> — the real commit proof: a resolved primary, not just a good OK flag
    local label="$1" rstatus
    rstatus=$(_rauc_status)
    # The booted slot's own block is "(/dev/disk/by-partlabel/system-N, ext4, booted)" — the
    # device path sits BETWEEN the paren and the word, so a bare "(booted)" substring never
    # matches; and "boot status: good" is two lines below that block header, not on it.
    if printf '%s' "$rstatus" | grep -q "^Activated: *rootfs\." &&
        printf '%s' "$rstatus" | grep -A2 -F ", booted)" | grep -q "boot status: good"; then
        ok "rauc status reports the booted slot committed $label: $(printf '%s' "$rstatus" | grep -E '^Activated|booted\)|boot status')"
    else
        bad "rauc status does not report a committed booted slot $label: $(printf '%s' "$rstatus" | tr '\n' ' ' | cut -c1-600)"
    fi
}
_phase_install_commit() {
    info "phase: installed-disk commit (#2352 — seed, deferred first commit, one unaided reboot)"

    # The seed proof: A_OK/B_OK, not A_TRY — GRUB unconditionally marks A_TRY=1 the instant it
    # ATTEMPTS slot A, which already happened by the time SSH answers, seed or no seed.
    local genv
    genv=$(_read_genv)
    if [ "$(_genv_field "$genv" A_OK)" = 1 ] && [ "$(_genv_field "$genv" B_OK)" = 0 ]; then
        ok "pithead-install seeded the installed disk's grubenv good before any boot gate ran: $genv"
    else
        bad "installed disk's grubenv is not seeded good on first boot — pithead-install's seed did not survive: ${genv:-unreadable}"
    fi
    # Not yet committed by design (see header) — logged for the PR's evidence, not asserted:
    # "no bootable slot found" / Activated: none is the CORRECT reading here, not a failure.
    info "rauc status right after install: $(_rauc_status | tr '\n' ' ' | cut -c1-600)"

    # Boot 1 settling means firstboot consumed the preseed and brought the stack up headlessly —
    # by design (see header) pithead-boot does NOT also run this same boot.
    if provisioning_settled 900; then
        ok "boot 1 (headless provisioning) settled ($(provisioning_state))"
    else
        bad "boot 1 (headless provisioning) never settled ($(provisioning_state))"
    fi

    # ---- one unaided reboot: THIS is the boot that must commit -----------------------------
    # config.json exists now, so pithead-boot's condition should hold; its health gate must run
    # and call `rauc status mark-good`. No hands on it — _reboot_wait is the same primitive
    # provision-reboot.sh uses for the provisioned-machine reboot leg.
    _reboot_wait reboot 300 || bad "installed system never returned from the unaided reboot"
    local rootdev
    rootdev=$(_ssh "lsblk -no PKNAME \$(findmnt -no SOURCE /)" | head -1)
    if [ "$rootdev" = "vda" ]; then
        ok "the unaided reboot stayed on the target disk (vda)"
    else
        bad "the unaided reboot landed on '${rootdev:-unknown}' — expected the target disk (vda)"
    fi
    if provisioning_settled 900; then
        ok "boot 2 (pithead-boot's own first chance) settled ($(provisioning_state))"
    else
        bad "boot 2 never settled ($(provisioning_state))"
    fi
    # rauc status, not grubenv, is the pass/fail oracle (see header) — polled the same way
    # provision-reboot.sh polls grubenv, because mark-good can lag settling by a beat.
    local tries=0 rstatus=""
    while [ "$tries" -lt 18 ]; do
        rstatus=$(_rauc_status)
        printf '%s' "$rstatus" | grep -q "^Activated: *rootfs\." && break
        sleep 10
        tries=$((tries + 1))
    done
    _assert_rauc_committed "after boot 2 (the unaided reboot)"
    info "grubenv after boot 2: $(_read_genv)"
    unset -f _read_genv _genv_field _rauc_status _assert_rauc_committed
}
