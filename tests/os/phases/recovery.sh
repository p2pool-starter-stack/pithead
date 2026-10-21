# shellcheck shell=bash disable=SC2034,SC2154
: "${OS_RUN_SUITE:?source via the suite runner}"
source "$SCRIPT_DIR/lib/recovery-invariants.sh" || return $?
source "$SCRIPT_DIR/recovery-wizard.sh" || return $?

_recovery_prepare() {
    local old="${PITHEAD_OLD_IMAGE:-}" bundle old_marker
    [ -f "$old" ] && [[ "${PITHEAD_OLD_IMAGE_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] || {
        bad "recovery requires an attested previous-release image and full source SHA"
        return 1
    }
    _vm_boot_disk "$old" && _wait_ssh 900 && _wizard_provision_capture 0 && _reset_slot_good_stack || return 1
    RECOVERY_OLD_SOURCE=$(_ssh cat /opt/pithead/BUILD_COMMIT) || return 1
    old_marker=$(_ssh cat /etc/pithead-test-marker) || return 1
    [ "$RECOVERY_OLD_SOURCE" = "$PITHEAD_OLD_IMAGE_COMMIT" ] &&
        [ "$RECOVERY_OLD_SOURCE" != "$RECOVERY_HEAD" ] || return 1
    _reboot_wait reboot 300 && _recovery_wait_slot A "$old_marker" "$RECOVERY_OLD_SOURCE" initial || return 1
    bundle=$(_build_bundle recovery) || {
        bundle_build_evidence
        return 1
    }
    _stage_bundle "$bundle" && _ssh 'cd /data/pithead && ./pithead os-update /data/update.bundle --yes' &&
        _reboot_wait reboot 300 && _recovery_wait_slot B recovery "$RECOVERY_HEAD" && _recovery_fallback_intact || return 1
    ok "recovery fixture: real previous-release A and health-committed candidate B"
}

_recovery_backup() {
    local remote
    _ssh 'cd /data/pithead && PITHEAD_BACKUP_PASSPHRASE="recovery matrix fixture" ./pithead backup -y' || return 1
    remote=$(_ssh 'ls -t /data/pithead/backups/pithead-backup-*.tar.gz.enc | head -1') || return 1
    [[ "$remote" == /data/pithead/backups/pithead-backup-*.tar.gz.enc ]] || return 1
    timeout 300 scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        "root@$ip:$remote" "$RECOVERY_ARCHIVE" || return 1
    RECOVERY_IDENTITY=$(_recovery_identity) && recovery_identity_matches "$RECOVERY_IDENTITY" "$RECOVERY_IDENTITY"
}

_recovery_chain_sentinels() {
    _ssh 'cd /data/pithead && set -a && . ./.env && set +a
test -n "$MONERO_DATA_DIR" && test -n "$TARI_DATA_DIR" || exit 1
mkdir -p "$MONERO_DATA_DIR" "$TARI_DATA_DIR" || exit 1
printf "%s\n%s\n" "$MONERO_DATA_DIR" "$TARI_DATA_DIR"
printf monero-recovery > "$MONERO_DATA_DIR/.recovery-matrix-sentinel" &&
printf tari-recovery > "$TARI_DATA_DIR/.recovery-matrix-sentinel" && sync'
}

_recovery_reset_cell() {
    local operation="$1" route="$2" label="$1 -> $2" before mark dirs dir cmd expected failed=0 identity
    _recovery_wait_slot B recovery "$RECOVERY_HEAD" && _recovery_backup || return 1
    dirs=$(_recovery_chain_sentinels) && before=$(_recovery_project_ids) && [ -n "$before" ] || return 1
    mark=$(wc -c <"$SERIAL") || return 1
    SA_SERIAL_OFFSET=$mark
    _reboot_wait "cd /data/pithead && ./pithead $operation -y" 300 && _wait_setup_page 120 || {
        bad "$label: reset returns to the setup page"
        return 1
    }
    ok "$label: reset returns to the setup page"
    _recovery_post_op "$label" "$before" || failed=1
    while IFS= read -r dir; do
        [[ "$dir" =~ ^/data/[a-zA-Z0-9_./-]+$ ]] || return 1
        case "$dir" in */monero) expected=monero-recovery ;; */tari) expected=tari-recovery ;; *) return 1 ;; esac
        cmd="test \"\$(cat '$dir/.recovery-matrix-sentinel')\" = '$expected'"
        [ "$operation" != factory-reset ] || cmd="test ! -e '$dir/.recovery-matrix-sentinel'"
        if _ssh "$cmd" </dev/null; then
            ok "$label: chain sentinel $([ "$operation" = factory-reset ] && echo erased || echo preserved) ($dir)"
        else
            bad "$label: chain sentinel contract failed ($dir)"
            failed=1
        fi
    done <<<"$dirs"
    case "$route" in
    wizard-setup) _wizard_provision_capture "$mark" || return 1 ;;
    wizard-restore) _recovery_wizard_restore || return 1 ;;
    cli-restore)
        _ssh 'mkdir -p /data/pithead/backups' &&
            timeout 300 scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
                "$RECOVERY_ARCHIVE" "root@$ip:/data/pithead/backups/recovery-matrix.tar.gz.enc" &&
            _ssh 'cd /data/pithead && ./pithead down && PITHEAD_BACKUP_PASSPHRASE="recovery matrix fixture" ./pithead restore -y backups/recovery-matrix.tar.gz.enc && ./pithead up' || return 1
        ;;
    esac
    if _reset_slot_good_stack && _recovery_dashboard_ready; then
        ok "$label: healthy stack and dashboard own the web ports"
    else
        bad "$label: healthy stack and dashboard own the web ports"
        return 1
    fi
    if [ "$route" != wizard-setup ]; then
        identity=$(_recovery_identity) || return 1
        if recovery_identity_matches "$RECOVERY_IDENTITY" "$identity"; then
            ok "$label: restored configuration and secret fingerprints match the backup"
        else
            bad "$label: restored configuration and secret fingerprints match the backup"
            return 1
        fi
    fi
    _recovery_post_op "$label after recovery" "$before" || failed=1
    _slot_invariant_reboot "$label" && _recovery_fallback_intact || return 1
    [ "$failed" -eq 0 ]
}

_recovery_saved_setup() {
    local route="$1" label="Set up again -> $1" token jar="" saved before after code cfg
    _recovery_wait_slot B recovery "$RECOVERY_HEAD" && _recovery_backup || return 1
    before=$(_ssh 'sha256sum /data/pithead/config.json') || return 1
    _setup_again_boot 300 && _setup_again_session || return 1
    saved=$(_ssh "cat $SA_SPOOL/saved-role.json") || {
        rm -f "$jar"
        return 1
    }
    jq -e '.role == "pithead"' <<<"$saved" >/dev/null || {
        rm -f "$jar"
        return 1
    }
    case "$route" in
    keep)
        curl -fsSk --max-time 10 -b "$jar" -X POST "https://$ip/keep-role" >/dev/null || {
            rm -f "$jar"
            return 1
        }
        rm -f "$jar"
        ;;
    wizard-restore) _recovery_wizard_restore "$jar" || return 1 ;;
    wizard-setup)
        wizard_state_poll "$ip" "$jar" '.config // empty' || {
            rm -f "$jar"
            return 1
        }
        cfg=$(provision_browser_config "$WIZ_STATE" | jq -c '.dashboard.energy.cost_per_kwh = 0.12345') || {
            rm -f "$jar"
            return 1
        }
        code=$(curl -sSk --max-time 30 -b "$jar" --data-urlencode "config=$cfg" --data-urlencode auth_mode=auto \
            "https://$ip/submit" -o /dev/null -w '%{http_code}')
        [ "$code" = 200 ] || {
            rm -f "$jar"
            return 1
        }
        _recovery_handoff "$jar" || return 1
        ;;
    esac
    _reset_slot_good_stack && _recovery_dashboard_ready || return 1
    if [ "$route" = wizard-setup ]; then
        _ssh "jq -e '.dashboard.energy.cost_per_kwh == 0.12345' /data/pithead/config.json" >/dev/null || {
            bad "$label: submitted setting took effect"
            return 1
        }
        ok "$label: submitted setting took effect"
    fi
    if [ "$route" = wizard-restore ]; then
        after=$(_recovery_identity) && recovery_identity_matches "$RECOVERY_IDENTITY" "$after" || {
            bad "$label: restored configuration and secret fingerprints match the backup"
            return 1
        }
        ok "$label: restored configuration and secret fingerprints match the backup"
    fi
    if [ "$route" = keep ]; then
        after=$(_ssh 'sha256sum /data/pithead/config.json') || return 1
        [ "$before" = "$after" ] || {
            bad "$label: saved configuration unchanged"
            return 1
        }
        ok "$label: saved configuration unchanged"
    fi
    _slot_invariant_reboot "$label" && _recovery_fallback_intact
}

phase_recovery() {
    local RECOVERY_HEAD RECOVERY_OLD_SOURCE RECOVERY_ARCHIVE RECOVERY_IDENTITY operation route
    RECOVERY_HEAD=$(git rev-parse HEAD) || return 1
    RECOVERY_ARCHIVE=$(mktemp "${TMPDIR:?}/recovery-matrix.XXXXXX") || return 1
    chmod 600 "$RECOVERY_ARCHIVE"
    if ! _recovery_prepare; then
        bad "recovery two-slot fixture could not be prepared"
        rm -f "$RECOVERY_ARCHIVE"
        return 1
    fi
    for operation in config-reset factory-reset; do
        for route in wizard-setup wizard-restore cli-restore; do
            if ! _recovery_reset_cell "$operation" "$route"; then
                bad "$operation -> $route: recovery matrix cell failed"
                rm -f "$RECOVERY_ARCHIVE"
                return 1
            fi
        done
        it_skip_leg "$operation -> Set up again" "resets erase saved settings; docs/appliance.md#set-up-again" by-design
    done
    for route in keep wizard-setup wizard-restore; do
        if ! _recovery_saved_setup "$route"; then
            bad "Set up again -> $route: saved-settings operation failed"
            rm -f "$RECOVERY_ARCHIVE"
            return 1
        fi
    done
    it_skip_leg "appliance -> DIY uninstall" "uninstall is the DIY removal path; docs/operations.md#what-uninstall-removes" by-design
    rm -f "$RECOVERY_ARCHIVE"
}
