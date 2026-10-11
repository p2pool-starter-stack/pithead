# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# Real provisioned A -> os-update B fixture. Never manufacture bootloader authority.
_reset_slot_snapshot() {
    SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh 'slot=$(sed -n "s/.*rauc.slot=\([AB]\).*/\1/p" /proc/cmdline)
printf "%s|%s|%s\n" "$slot" "$(cat /etc/pithead-test-marker)" "$(cat /opt/pithead/BUILD_COMMIT)"
grub-editenv /boot/efi/grub/grubenv list
rauc status --output-format=json' 2>/dev/null
}

_reset_slot_wait() { # <slot> <marker> <committed: yes/no> [seconds]
    local until=$((SECONDS + ${4:-900})) snapshot status gate
    local SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}"
    while [ "$SECONDS" -lt "$until" ]; do
        snapshot=$(_reset_slot_snapshot) || snapshot=""
        if printf '%s\n' "$snapshot" | grep -qx "$1|$2|$(git rev-parse HEAD)" &&
            printf '%s\n' "$snapshot" | grep -qx A_OK=1 &&
            printf '%s\n' "$snapshot" | grep -qx A_TRY=0 &&
            printf '%s\n' "$snapshot" | grep -qx 'ORDER=B A'; then
            status=$(printf '%s\n' "$snapshot" | sed -n '/^{/,$p')
            if printf '%s' "$status" | jq -e '.booted == "B" and .boot_primary == "rootfs.1" and any(.slots[]; .["rootfs.1"].boot_status == "good")' >/dev/null 2>&1 &&
                printf '%s\n' "$snapshot" | grep -qx B_TRY=0; then
                if [ "$3" = no ]; then
                    return 0
                fi
                gate=$(_ssh 'systemctl show pithead-boot.service -p ActiveState -p SubState -p Result -p ExecMainStatus -p ConditionResult') || gate=""
                if printf '%s\n' "$gate" | grep -qx ActiveState=active &&
                    printf '%s\n' "$gate" | grep -qx SubState=exited &&
                    printf '%s\n' "$gate" | grep -qx Result=success &&
                    printf '%s\n' "$gate" | grep -qx ExecMainStatus=0 &&
                    printf '%s\n' "$gate" | grep -qx ConditionResult=yes &&
                    _ssh "journalctl -b -u pithead-boot --no-pager | grep -q 'booted slot committed'"; then
                    return 0
                fi
            fi
        fi
        sleep 5
    done
    return 1
}

_reset_slot_good_stack() {
    local until=$((SECONDS + 900)) SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}"
    while [ "$SECONDS" -lt "$until" ]; do
        if _ssh 'cd /data/pithead && ./pithead doctor --json' 2>/dev/null |
            jq -e '.summary.fail == 0' >/dev/null 2>&1; then
            return 0
        fi
        sleep 10
    done
    return 1
}

_reset_slot_observe() { # <literal row label> <require provisioned commit>
    local seconds=900
    [ "$2" != no ] || seconds=120
    if _reset_slot_wait B v2 "$2" "$seconds"; then
        ok "$1"
    else
        bad "$1 (expected B|v2, good primary B, previous A good and ORDER=B A)"
    fi
}

_reset_slot_rearm() {
    # A failed round remains red; a failed recovery makes later rounds missing.
    # shellcheck disable=SC2034 # _ssh reads this dynamically scoped probe timeout.
    local SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" until=$((SECONDS + 900)) gate
    if [ "$(_ssh "sed -n 's/.*rauc.slot=\([AB]\).*/\1/p' /proc/cmdline")" = A ]; then
        info "reset-slot: re-arming the installed candidate after observed fallback"
        # A provisioned fallback must finish committing before we leave it, so its
        # consumed attempt cannot contaminate the next round's previous-slot checks.
        if _ssh 'test -e /data/pithead/config.json'; then
            while [ "$SECONDS" -lt "$until" ]; do
                gate=$(_ssh 'systemctl show pithead-boot.service -p ActiveState -p SubState') || gate=""
                printf '%s\n' "$gate" | grep -qx SubState=exited && break
                sleep 5
            done
        fi
        _ssh 'rauc status mark-active other' || {
            bad "could not re-arm the candidate"
            rs_ready=no
            return 0
        }
        _reboot_wait reboot 300 || return 1
    fi
    if ! _reset_slot_wait B v2 yes; then
        bad "next reset round cannot establish committed B v2 with good previous A"
        rs_ready=no
    fi
    return 0
}

_phase_reset_slot() {
    local bundle archive mark ready=yes rs_ready=yes
    info "reset-slot preconditions: real health-committed A, then real os-update to B v2"
    _reboot_wait reboot 300 || {
        bad "reset-slot precondition guest unreachable"
        return 1
    }
    local until=$((SECONDS + 900))
    while [ "$SECONDS" -lt "$until" ]; do
        if SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh 'test "$(cat /etc/pithead-test-marker)" = v1 && grep -q "rauc.slot=A" /proc/cmdline && grub-editenv /boot/efi/grub/grubenv list | grep -qx A_TRY=0' &&
            SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh 'grub-editenv /boot/efi/grub/grubenv list | grep -qx A_OK=1' &&
            (SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh 'rauc status --output-format=json' |
                jq -e '.booted == "A" and .boot_primary == "rootfs.0" and any(.slots[]; .["rootfs.0"].boot_status == "good")' >/dev/null 2>&1) &&
            SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh "journalctl -b -u pithead-boot --no-pager | grep -q 'booted slot committed'"; then
            break
        fi
        sleep 5
    done
    if [ "$SECONDS" -ge "$until" ]; then
        bad "reset-slot precondition A v1 did not health-commit"
        it_skip_leg reset-slot "health-committed A unavailable" missing
        return 0
    fi
    bundle=$(_build_bundle v2) || {
        bad "reset-slot v2 bundle build failed"
        bundle_build_evidence
        ready=no
    }
    if [ "$ready" = yes ]; then
        _stage_bundle "$bundle" && _ssh 'cd /data/pithead && ./pithead os-update /data/update.bundle --yes' || {
            bad "reset-slot real os-update failed"
            ready=no
        }
    fi
    if [ "$ready" = no ]; then
        it_skip_leg reset-slot "real update fixture unavailable" missing
        return 0
    fi
    _reboot_wait reboot 300 || {
        bad "reset-slot updated guest unreachable"
        return 1
    }
    if ! _reset_slot_wait B v2 yes; then
        bad "reset-slot precondition B v2 did not health-commit with good previous A"
        it_skip_leg reset-slot "health-committed B unavailable" missing
        return 0
    fi
    ok "reset-slot real update created health-committed B v2 with good previous A"
    if ! _ssh 'cd /data/pithead && PITHEAD_BACKUP_PASSPHRASE="reset slot fixture" ./pithead backup -y'; then
        bad "reset-slot encrypted backup failed"
        it_skip_leg reset-slot "encrypted backup unavailable" missing
        return 0
    fi
    archive=$(_ssh 'ls -t /data/pithead/backups/pithead-backup-*.tar.gz.enc | head -1')
    if [ -z "$archive" ] || ! _ssh "test -s '$archive'"; then
        bad "reset-slot encrypted backup archive missing"
        it_skip_leg reset-slot "encrypted backup unavailable" missing
        return 0
    fi
    # Round 1: finish the setup page, then reboot. Offset rejects stale wizard tokens.
    mark=$(wc -c <"$SERIAL")
    _reboot_wait 'cd /data/pithead && ./pithead config-reset -y' 300 || return 1
    _wait_setup_page 120 && _reset_slot_observe "round 1 reset boot preserves B v2 and previous A" no || bad "round 1 setup page unavailable"
    if ! _wizard_provision_capture "$mark" || ! _reset_slot_good_stack; then
        bad "round 1 setup did not return a healthy stack"
    fi
    _reboot_wait reboot 300 || return 1
    _reset_slot_observe "round 1 setup and normal reboot preserve committed B v2" yes
    _reset_slot_rearm || return 1
    [ "$rs_ready" = yes ] || {
        it_skip_leg reset-slot "later rounds lack the required B fixture" missing
        return 0
    }

    # Round 2: the tester's CLI restore/up verbs on the same encrypted archive.
    _reboot_wait 'cd /data/pithead && ./pithead config-reset -y' 300 || return 1
    _wait_setup_page 120 && _reset_slot_observe "round 2 reset boot preserves B v2 and previous A" no || bad "round 2 setup page unavailable"
    if ! _ssh "cd /data/pithead && PITHEAD_BACKUP_PASSPHRASE='reset slot fixture' ./pithead restore -y '$archive' && ./pithead up" ||
        ! _reset_slot_good_stack; then
        bad "round 2 CLI restore and up did not return a healthy stack"
    fi
    _reboot_wait reboot 300 || return 1
    _reset_slot_observe "round 2 CLI restore and normal reboot preserve committed B v2" yes
    _reset_slot_rearm || return 1
    [ "$rs_ready" = yes ] || {
        it_skip_leg reset-slot "later rounds lack the required B fixture" missing
        return 0
    }

    # Round 3: reboot with setup still open, then complete the new boot's setup page.
    _reboot_wait 'cd /data/pithead && ./pithead config-reset -y' 300 || return 1
    _wait_setup_page 120 && _reset_slot_observe "round 3 reset boot preserves B v2 and previous A" no || bad "round 3 setup page unavailable"
    mark=$(wc -c <"$SERIAL")
    _reboot_wait reboot 300 || return 1
    _wait_setup_page 120 && _reset_slot_observe "round 3 open setup page reboot preserves B v2 and previous A" no || bad "round 3 rebooted setup page unavailable"
    if ! _wizard_provision_capture "$mark" || ! _reset_slot_good_stack; then
        bad "round 3 setup did not return a healthy stack"
    fi
    _reboot_wait reboot 300 || return 1
    _reset_slot_observe "round 3 finished setup and normal reboot preserve committed B v2" yes
    _reset_slot_rearm || return 1
    return 0
}
