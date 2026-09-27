# The firstboot install window and the restore/installer-credential cleanup around it, split out
# of 12-firstboot-wizard.sh along that boundary. firstboot_wizard opens the window with
# wizard_install_begin and closes it through wizard_install_finish or wizard_install_failed_page;
# the rest clear what an accepted, rejected or failed submission left behind — the volatile
# restore passphrase and archive, the installer's config candidate and credentials card, and the
# fleet stick's own pre-seed — so none of it outlives the attempt.
# The lock and the marker that OPEN every install path: taken before the first write, which is `installing` itself, so
# the lock timeout's promise that nothing was changed is literally true. No caller holds it across a human wait — the
# two card paths sit past their handoff-ack, and the bare keep-reinstall has no card and never waits (#1482).
wizard_install_begin() { # <spool-dir>
    mutation_lock_acquire firstboot-install
    wizard_spool_publish "$1" installing true
}

# The switch-off every install path ends on, and where the window closes — held across the poweroff for the reason
# factory-reset holds across its reboot: the gap before the machine goes dark is precisely when another verb must not
# start. No confirmation step, deliberately — an operator who removes the stick BEFORE pressing anything takes the
# running filesystem with it, and a machine already dark by the time anyone reaches it removes that mistake entirely.
# The setup transaction is cleared before the switch-off, so no half-consumed submission rides into the next boot.
wizard_install_finish() { # <engine> <spool-dir> <headline> <closing line>
    _console "" "$3" "When the machine is dark, remove the USB stick and switch it back on." "$4"
    sleep 8 # long enough for the page's poll to show the switch-off steps
    "$1" rm -f pithead-wizard >/dev/null 2>&1 || true
    wizard_clear_submission_transaction "$2" || return 1
    _console "" "Shutting down. Remove the USB stick, then switch the machine on."
    sleep 3
    systemctl poweroff
    mutation_lock_release
}

wizard_install_failed_page() { # <spool-dir> <what failed> — the page gets the disk list and the reason back; the window closes here
    publish_disk_inventory "$1"
    warn "$2 failed — the page shows the reason."
    local rc=0
    wizard_clear_submission_transaction "$1" || rc=1
    mutation_lock_release
    sleep 2
    return "$rc"
}

wizard_publish_retry_config() { # <spool-dir> <candidate> <installer>
    if [ "$3" -eq 1 ]; then
        wizard_spool_publish "$1" last-attempt.json strip_config_secrets "$2"
    else
        wizard_spool_publish "$1" last-attempt.json jq -c . "$2"
    fi
}

wizard_clear_restore_state() { # <consume-rc> <spool-dir> <passphrase-spool> [<carry-dir>]
    [ "$1" = 2 ] || clear_restore_submission "$2" "$3" || return 1
    clear_restore_carry "${4:-$(restore_carry_dir)}" || return 1
    wizard_clear_submission_transaction "$2"
}

wizard_restore_installer_preseeds() { # <saved-config> <restore-consume-rc>
    local rc=0
    if [ "$2" = 0 ]; then
        return 0 # pithead-install --no-preseeds left the source files untouched
    elif [ -n "$1" ] && [ -s "$1" ]; then
        install -m 600 "$1" /boot/efi/pithead-config.json && rm -f "$1" || rc=1
    else
        rm -f /boot/efi/pithead-config.json || rc=1
    fi
    [ "$rc" = 0 ] || warn "Could not restore the installer pre-seed files safely — do not remove the stick."
    return "$rc"
}

wizard_cleanup_installer_credentials() { # <saved-config> <candidate> <card> <rec> <spool> <restore-spool> <carry>
    local rc=0
    wizard_restore_installer_preseeds "$1" "$4" || rc=1
    clear_setup_candidate "$2" "$3" || rc=1
    clear_legacy_restore_carry /boot/efi || rc=1
    wizard_clear_restore_state "$4" "$5" "$6" "$7" || rc=1
    return "$rc"
}
