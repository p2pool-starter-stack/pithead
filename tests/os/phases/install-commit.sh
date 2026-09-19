# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# #2352: a fresh USB install left both RAUC slots reading `bad` on a physical box, and
# pithead-boot's health-gated commit never ran on the disk's first provisioned boot. mkimage.sh's
# grubenv seed is asserted for the IMAGE in verify-image.sh; pithead-install's copy of that seed
# onto the INSTALLED disk, and the boot gate that must commit it, had never been checked at all —
# the exact gap the issue's "Test" section names. Runs right after _phase_install_initial, on the
# same guest, so $ip and the SSH connection it left are still good.
_phase_install_commit() {
    info "phase: installed-disk commit (#2352 — seed, first-boot commit, one unaided reboot)"

    # Seeded good is not committed: pithead-install writes ORDER/A_OK/A_TRY/B_OK identically to
    # mkimage.sh (both must match, or an installed disk and a fresh image would boot two
    # different rules), but nothing had ever read that back off a disk pithead-install wrote to,
    # only off the image. Checked before render, the boot gate or a reboot get a chance to touch it.
    local genv0 rstatus0
    genv0=$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')
    case "$genv0" in
    *A_OK=1*A_TRY=0*B_OK=0* | *A_TRY=0*A_OK=1*B_OK=0*)
        ok "pithead-install seeded the installed disk's grubenv good before any boot gate ran: $genv0"
        ;;
    *)
        bad "installed disk's grubenv is not seeded good on first boot — pithead-install's seed did not survive: ${genv0:-unreadable}"
        ;;
    esac
    rstatus0=$(_ssh "rauc status 2>&1" 2>/dev/null)
    if printf '%s' "$rstatus0" | grep -F "(booted)" | grep -q "boot status: good"; then
        ok "rauc status reports the booted slot good right after install: $(printf '%s' "$rstatus0" | grep -F booted | tr -s ' ')"
    else
        bad "rauc status does not report the booted slot good after install: $(printf '%s' "$rstatus0" | tr '\n' ' ' | cut -c1-300)"
    fi

    # Seeded good is only half the promise — pithead-boot's health gate must still run
    # `rauc status mark-good` (A_TRY=0) once the stack answers and doctor passes. Wait for the
    # boot unit itself to finish (provisioning_settled), then read back exactly what it left.
    if provisioning_settled 900; then
        ok "first provisioned boot on the installed disk settled ($(provisioning_state))"
    else
        bad "first provisioned boot on the installed disk never settled ($(provisioning_state))"
    fi
    local genv1 rstatus1
    genv1=$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')
    case "$genv1" in
    *A_OK=1*A_TRY=0* | *A_TRY=0*A_OK=1*)
        ok "the first provisioned boot committed the installed slot (A_OK=1 A_TRY=0): $genv1"
        ;;
    *)
        bad "the installed slot never self-committed on its first provisioned boot — grubenv: ${genv1:-unreadable}"
        ;;
    esac
    rstatus1=$(_ssh "rauc status 2>&1" 2>/dev/null)
    if printf '%s' "$rstatus1" | grep -F "(booted)" | grep -q "boot status: good"; then
        ok "rauc status reports the booted slot good after the first provisioned boot: $(printf '%s' "$rstatus1" | grep -F booted | tr -s ' ')"
    else
        bad "rauc status still reports the booted slot bad after the first provisioned boot: $(printf '%s' "$rstatus1" | tr '\n' ' ' | cut -c1-300)"
    fi

    # ---- one unaided reboot: the same slot must still be booted and committed --------------
    # Question 3 the issue asked: what the selector does next with A/B's state as the first
    # boot left it. No hands on it — _reboot_wait is the same primitive provision-reboot.sh
    # uses for the provisioned-machine reboot leg.
    _reboot_wait reboot 300 || bad "installed system never returned from the unaided reboot"
    local rootdev2
    rootdev2=$(_ssh "lsblk -no PKNAME \$(findmnt -no SOURCE /)" | head -1)
    if [ "$rootdev2" = "vda" ]; then
        ok "the unaided reboot stayed on the target disk (vda)"
    else
        bad "the unaided reboot landed on '${rootdev2:-unknown}' — expected the target disk (vda)"
    fi
    local genv2="" tries4=0
    while [ "$tries4" -lt 18 ]; do
        genv2=$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')
        case "$genv2" in
        *A_OK=1*A_TRY=0* | *A_TRY=0*A_OK=1*) break ;;
        esac
        sleep 10
        tries4=$((tries4 + 1))
    done
    case "$genv2" in
    *A_OK=1*A_TRY=0* | *A_TRY=0*A_OK=1*)
        ok "the same slot is still booted and committed after one unaided reboot: $genv2"
        ;;
    *)
        bad "the slot did not stay booted/committed after one unaided reboot — grubenv: ${genv2:-unreadable}"
        ;;
    esac
    local rstatus2
    rstatus2=$(_ssh "rauc status 2>&1" 2>/dev/null)
    if printf '%s' "$rstatus2" | grep -F "(booted)" | grep -q "boot status: good"; then
        ok "rauc status reports the booted slot good after the unaided reboot: $(printf '%s' "$rstatus2" | grep -F booted | tr -s ' ')"
    else
        bad "rauc status reports the booted slot bad after the unaided reboot: $(printf '%s' "$rstatus2" | tr '\n' ' ' | cut -c1-300)"
    fi
}
