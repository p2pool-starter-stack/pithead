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
# report found it (both slots `bad`, GRUB's own "nothing selectable" fallback silently masking it
# because the only populated slot is also GRUB's hardcoded default)?
_read_genv() { _ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' '; }
_genv_field() { printf '%s' "$1" | grep -oE "(^| )$2=[^ ]*" | tail -1 | cut -d= -f2; } # <genv> <KEY>
# A_TRY=0 alone is not proof of a commit: GRUB's own "nothing selectable" branch (grub.cfg) clears
# a stale A_TRY back to 0 on EVERY boot where nothing was selectable, whether or not RAUC ever ran
# mark-good — and it leaves B_TRY=1 as a side effect no real commit produces (mark-good only ever
# touches the BOOTED slot). Requiring B_TRY=0 too is what tells the two apart.
_genv_committed() { # <genv> -> 0 iff slot A is really committed, not just GRUB's fallback artifact
    [ "$(_genv_field "$1" A_OK)" = 1 ] && [ "$(_genv_field "$1" A_TRY)" = 0 ] && [ "$(_genv_field "$1" B_TRY)" = 0 ]
}
_assert_rauc_booted_good() { # <label> — reads rauc status itself, for the PR evidence text
    local label="$1" rstatus
    rstatus=$(_ssh "rauc status 2>&1" 2>/dev/null)
    if printf '%s' "$rstatus" | grep -F "(booted)" | grep -q "boot status: good"; then
        ok "rauc status reports the booted slot good $label: $(printf '%s' "$rstatus" | grep -F booted | tr -s ' ')"
    else
        bad "rauc status does not report the booted slot good $label: $(printf '%s' "$rstatus" | tr '\n' ' ' | cut -c1-500)"
    fi
}
_phase_install_commit() {
    info "phase: installed-disk commit (#2352 — seed, deferred first commit, one unaided reboot)"

    # The seed proof: A_OK/B_OK, not A_TRY — GRUB unconditionally marks A_TRY=1 the instant it
    # ATTEMPTS slot A, which already happened by the time SSH answers, seed or no seed. rauc
    # status is read for the PR's evidence only (info, not asserted): with A_TRY=1 and nothing yet
    # committed, "no bootable slot found" is the CORRECT, expected reading on every real boot,
    # not a failure — asserting good here would fail on every honest appliance.
    local genv rstatus
    genv=$(_read_genv)
    if [ "$(_genv_field "$genv" A_OK)" = 1 ] && [ "$(_genv_field "$genv" B_OK)" = 0 ]; then
        ok "pithead-install seeded the installed disk's grubenv good before any boot gate ran: $genv"
    else
        bad "installed disk's grubenv is not seeded good on first boot — pithead-install's seed did not survive: ${genv:-unreadable}"
    fi
    rstatus=$(_ssh "rauc status 2>&1" 2>/dev/null)
    info "rauc status right after install (not yet committed by design): $(printf '%s' "$rstatus" | tr '\n' ' ' | cut -c1-500)"

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
    local tries=0
    while [ "$tries" -lt 18 ]; do
        genv=$(_read_genv)
        _genv_committed "$genv" && break
        sleep 10
        tries=$((tries + 1))
    done
    if _genv_committed "$genv"; then
        ok "boot 2 committed the installed slot for real (A_OK=1 A_TRY=0 B_TRY=0, not GRUB's fallback artifact): $genv"
    else
        bad "the installed slot never really committed on boot 2 — grubenv: ${genv:-unreadable} (A_TRY=0 with B_TRY=1 is GRUB's 'nothing selectable' fallback clearing a stale try flag, NOT a commit — exactly what the field report's both-slots-bad state looks like from here)"
    fi
    _assert_rauc_booted_good "after boot 2 (the unaided reboot)"
    unset -f _read_genv _genv_field _genv_committed _assert_rauc_booted_good
}
