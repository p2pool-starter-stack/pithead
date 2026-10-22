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
    _vm_boot_disk "$old" || {
        bad "recovery fixture: previous-release boot failed"
        return 1
    }
    _wait_ssh 900 || {
        bad "recovery fixture: previous-release SSH failed"
        return 1
    }
    _wizard_provision_capture 0 || {
        bad "recovery fixture: previous-release provisioning failed"
        return 1
    }
    _reset_slot_good_stack || {
        bad "recovery fixture: previous-release health failed"
        return 1
    }
    RECOVERY_OLD_SOURCE=$(_ssh cat /opt/pithead/BUILD_COMMIT) || return 1
    old_marker=$(_ssh 'if test -e /etc/pithead-test-marker; then cat /etc/pithead-test-marker; fi') || {
        bad "recovery fixture: previous-release marker read failed"
        return 1
    }
    [ "$RECOVERY_OLD_SOURCE" = "$PITHEAD_OLD_IMAGE_COMMIT" ] &&
        [ "$RECOVERY_OLD_SOURCE" != "$RECOVERY_HEAD" ] || {
        bad "recovery fixture: previous-release source identity failed"
        return 1
    }
    _reboot_wait reboot 300 && _recovery_wait_slot A "$old_marker" "$RECOVERY_OLD_SOURCE" initial || return 1
    bundle=$(_build_bundle recovery) || {
        bundle_build_evidence
        return 1
    }
    _stage_bundle "$bundle" && _ssh 'cd /data/pithead && ./pithead os-update /data/update.bundle --yes' &&
        _reboot_wait reboot 300 && _recovery_wait_slot B recovery "$RECOVERY_HEAD" && _recovery_fallback_intact || return 1
    ok "recovery fixture: real previous-release A and health-committed candidate B"
}

_recovery_chain_sentinels() {
    _ssh 'cd /data/pithead && set -a && . ./.env && set +a
test -n "$MONERO_DATA_DIR" && test -n "$TARI_DATA_DIR" || exit 1
mkdir -p "$MONERO_DATA_DIR" "$TARI_DATA_DIR" || exit 1
printf "%s\n%s\n" "$MONERO_DATA_DIR" "$TARI_DATA_DIR"
printf monero-recovery > "$MONERO_DATA_DIR/.recovery-matrix-sentinel" &&
printf tari-recovery > "$TARI_DATA_DIR/.recovery-matrix-sentinel" && sync'
}

_recovery_preserved() {
    local dirs="$1" identity="$2" dir expected after
    while IFS= read -r dir; do
        [[ "$dir" =~ ^/data/[a-zA-Z0-9_./-]+$ ]] || return 1
        case "$dir" in */monero) expected=monero-recovery ;; */tari) expected=tari-recovery ;; *) return 1 ;; esac
        if _ssh "test \"\$(cat '$dir/.recovery-matrix-sentinel')\" = '$expected'" </dev/null; then
            ok "config-reset: chain sentinel preserved ($dir)"
        else
            bad "config-reset: chain sentinel preservation failed ($dir)"
            return 1
        fi
    done <<<"$dirs"
    after=$(_recovery_identity) && recovery_identity_matches "$identity" "$after" || {
        bad "config-reset: machine and Tor identities preserved"
        return 1
    }
    ok "config-reset: machine and Tor identities preserved"
}

_recovery_config_reset() {
    local before identity dirs mark failed=0
    _recovery_wait_slot B recovery "$RECOVERY_HEAD" || return 1
    dirs=$(_recovery_chain_sentinels) && before=$(_recovery_project_ids) && [ -n "$before" ] &&
        identity=$(_recovery_identity) && recovery_identity_matches "$identity" "$identity" || return 1
    mark=$(wc -c <"$SERIAL") || return 1
    _reboot_wait 'cd /data/pithead && ./pithead config-reset -y' 300 && _wait_setup_page 120 || {
        bad "config-reset -> wizard-setup: reset returns to the setup page"
        return 1
    }
    ok "config-reset -> wizard-setup: reset returns to the setup page"
    _recovery_post_op 'config-reset before provisioning' "$before" || failed=1
    _wizard_provision_capture "$mark" && _reset_slot_good_stack && _recovery_dashboard_ready || {
        bad "config-reset -> wizard-setup: healthy stack and dashboard own the web ports"
        return 1
    }
    ok "config-reset -> wizard-setup: healthy stack and dashboard own the web ports"
    _recovery_preserved "$dirs" "$identity" || failed=1
    _recovery_post_op 'config-reset after wizard setup' "$before" || failed=1
    _slot_invariant_reboot 'config-reset -> wizard-setup' && _recovery_fallback_intact || return 1
    _recovery_preserved "$dirs" "$identity" || failed=1
    _recovery_post_op 'config-reset after extra reboot' "$before" || failed=1
    [ "$failed" -eq 0 ]
}

phase_recovery() {
    local RECOVERY_HEAD RECOVERY_OLD_SOURCE
    RECOVERY_HEAD=$(git rev-parse HEAD) || return 1
    if ! _recovery_prepare || ! _recovery_config_reset; then
        bad "config-reset -> wizard-setup: two-slot recovery failed"
        return 1
    fi
}
