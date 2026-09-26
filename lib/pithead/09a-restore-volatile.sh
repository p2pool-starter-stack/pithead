# Volatile restore storage and its cleanup (#909, #1854). Every restore secret lives under /run:
# root-only tmpfs, gone at power-off. The submission spool is the only one mounted into the wizard
# container (as WIZARD_RESTORE); the carry dir, where an installer boot parks an ACCEPTED restore
# until it applies it to the target's data, and the staging root are never mounted into any
# container. Overridable so the shell suite can run this without root's /run. The clear_* helpers
# report a failed removal instead of hiding it: a caller that cannot clear a secret stops.
restore_carry_dir() { printf '%s' "${PITHEAD_RESTORE_CARRY_DIR:-/run/pithead-restore}"; }
restore_submission_dir() { printf '%s' "${PITHEAD_RESTORE_SUBMISSION_DIR:-/run/pithead-restore-submit}"; }
restore_stage_root() { printf '%s' "${PITHEAD_RESTORE_STAGE_ROOT:-/run/pithead-restore-stage}"; }
clear_restore_carry() { # [<carry-dir>]
    rm -rf -- "${1:-$(restore_carry_dir)}" || {
        warn "Could not clear the temporary restore handoff — reboot before trying another install."
        return 1
    }
}
clear_restore_stage() { # <volatile-stage-dir>
    rm -rf -- "$1" || {
        warn "Could not clear the private restore staging area — reboot before continuing."
        return 1
    }
}
clear_setup_candidate() { # <secret-file>...
    rm -f -- "$@" || {
        warn "Could not clear temporary setup credentials — do not leave the machine unattended."
        return 1
    }
}
clear_legacy_restore_carry() { # [<ESP-dir>]
    local dir="${1:-$PRESEED_DIR}"
    rm -f -- "$dir/pithead-restore.enc" "$dir/pithead-restore-pass" "$dir/pithead-setup-wizard" || {
        warn "Could not clear every legacy restore handoff file — do not leave the machine unattended."
        return 1
    }
}
clear_restore_submission() { # <archive-spool> [<passphrase-spool>] [<keep-archive|keep-marker>]
    local pass_dir="${2:-$1}" mode="${3:-}" paths
    case "$mode" in
    keep-archive) paths=("$1/restore-passphrase" "$pass_dir/restore-passphrase") ;;
    keep-marker) paths=("$1/restore-archive" "$pass_dir/restore-archive" "$1/restore-passphrase" "$pass_dir/restore-passphrase") ;;
    *) paths=("$1/restore-archive" "$pass_dir/restore-archive" "$1/restore-passphrase" "$pass_dir/restore-passphrase" "$1/restore-inflight") ;;
    esac
    rm -f -- "${paths[@]}" || {
        warn "Could not clear the submitted restore files — do not leave the machine unattended."
        wizard_spool_publish "$1" error.txt printf '%s' 'Could not clear the submitted restore files safely.' || true
        return 1
    }
}
clear_restore_snapshots() { # <private-dir>...
    local dir rc=0
    for dir in "$@"; do
        [ -z "$dir" ] || wizard_spool_clean_checked "$dir" || rc=1
    done
    [ "$rc" = 0 ] || {
        warn "Could not clear every private restore snapshot — do not leave the machine unattended."
        return 1
    }
}
