# config-reset temporarily removes the provisioned boot owner. Remember only a slot whose
# health gate already cleared TRY; firstboot may restore that same image's previous good state.
reset_slot_identity() {
    local slot source
    slot=$(os_booted_slot) || return 1
    source=$(cat "${PITHEAD_BUILD_COMMIT_FILE:-/opt/pithead/BUILD_COMMIT}" 2>/dev/null) || return 1
    case "$slot" in A | B) ;; *) return 1 ;; esac
    [[ "$source" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf '%s|%s\n' "$slot" "$source"
}

reset_slot_record_good() {
    is_appliance || return 0
    local identity state slot tmp gate property marker=.config-reset-good-slot
    rm -f "$marker" || return 1
    identity=$(reset_slot_identity) || {
        warn "Boot slot identity unavailable — reset cannot preserve a previously good slot."
        return 0
    }
    # GRUB also clears TRY when no slot is selectable. Only the successful provisioned
    # boot owner in this boot can establish that these counters came from a health commit.
    gate=$(systemctl show pithead-boot.service -p ActiveState -p SubState -p Result -p ExecMainStatus -p ConditionResult) || return 1
    for property in ActiveState=active SubState=exited Result=success ExecMainStatus=0 ConditionResult=yes; do
        if ! printf '%s\n' "$gate" | grep -qx "$property"; then
            log "Provisioned boot gate has not passed — reset keeps its normal fallback."
            return 0
        fi
    done
    slot=${identity%%|*}
    state=$(grub-editenv "${PITHEAD_GRUBENV:-/boot/efi/grub/grubenv}" list) || return 1
    if ! printf '%s\n' "$state" | grep -qx "${slot}_OK=1" ||
        ! printf '%s\n' "$state" | grep -qx "${slot}_TRY=0"; then
        log "Boot slot is not committed — reset keeps its normal health-gated fallback."
        return 0
    fi
    tmp=$(mktemp .config-reset-good-slot.XXXXXX) || return 1
    if ! printf '%s\n' "$identity" >"$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$marker"; then
        rm -f "$tmp"
        return 1
    fi
}

reset_slot_restore_good() { # <container engine>; called only after the wizard container starts
    is_appliance || return 0
    local identity saved state slot marker=.config-reset-good-slot
    [ -f "$marker" ] || return 0
    identity=$(reset_slot_identity) || return 1
    saved=$(cat "$marker") || return 1
    if [ "$identity" != "$saved" ]; then
        rm -f "$marker"
        return
    fi
    slot=${identity%%|*}
    state=$(grub-editenv "${PITHEAD_GRUBENV:-/boot/efi/grub/grubenv}" list) || return 1
    printf '%s\n' "$state" | grep -qx "${slot}_OK=1" || return 1
    [ "$("$1" inspect --format '{{.State.Running}}' pithead-wizard)" = true ] || return 1
    rauc status mark-good || return 1
    rm -f "$marker" || return 1
    log "Restored the previously good reset slot after firstboot started."
}
