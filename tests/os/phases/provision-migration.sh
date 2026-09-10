# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
_phase_provision_migration() {
    # ---- migration hold (#851): a data_migration update starts the chain only POST-commit ----
    # The deadlock rule's automatic-fallback half: on the first boot of a flagged bundle, pithead-boot must
    # bring the stack up WITHOUT the chain services, commit on that reduced stack, and only then start monerod
    # — so a failed health check still falls back onto /data the old OS can read. The journal lines are the
    # race-free evidence (the hold and the release are both logged); the podman poll additionally proves
    # monerod never ran while the slot was uncommitted.
    info "migration leg — build a data_migration bundle, install via os-update, boot it"
    local mig_bundle
    mig_bundle=$(PITHEAD_DATA_MIGRATION=true PITHEAD_MIN_OS_VERSION="$(tr -d ' \n' <VERSION)" _build_bundle vmig) || {
        bad "migration bundle build failed (/tmp/os-fault-bundle.log)"
        return 1
    }
    _stage_bundle "$mig_bundle" || {
        bad "staging the migration bundle failed"
        return 1
    }
    # os-update is the path that writes the pending marker (a bare rauc install does not) — and
    # this is also the first tier-4 exercise of os-update against a REAL bundle: it needs
    # unsquashfs on the appliance to read the manifest back, which CI's stubbed rauc never shows.
    local ou_out ou_rc
    ou_out=$(_ssh "cd /data/pithead && ./pithead os-update /data/update.bundle --yes 2>&1")
    ou_rc=$?
    if [ "$ou_rc" -ne 0 ]; then
        osupdate_failure_evidence "$ou_rc" "$ou_out" # both transport ends + the console, at the moment of death
        bad "pithead os-update failed on the guest — see the guest evidence above, and do not restate the cause without reading it"
        return 1
    fi
    marker=$(_ssh "cat /data/pithead/.os-migration-pending 2>/dev/null" | tr -d ' \r\n')
    if [ -n "$marker" ]; then
        ok "os-update left the migration-pending marker ($marker)"
    else
        bad "no migration-pending marker after installing a data_migration bundle"
        return 1
    fi
    _reboot_wait reboot 300 || {
        bad "guest never returned after booting the migration bundle"
        return 1
    }
    # Poll through the boot. The release line is logged at the commit boundary, BEFORE the
    # post-commit up — so any monerod observed running before that line is a chain service
    # beating the fallback decision, the exact ordering this rule exists to forbid.
    local chain_ran_early=0 released=0
    for _ in $(seq 120); do
        if _ssh "journalctl -u pithead-boot -b 2>/dev/null | grep -q 'chain services released'"; then
            released=1
            break
        fi
        if _ssh "podman ps --format '{{.Names}}' 2>/dev/null | grep -qx monerod"; then
            chain_ran_early=1
        fi
        sleep 5
    done
    if [ "$released" = 1 ]; then
        ok "the migrating slot committed and released the chain services"
        assert_appliance_hostname_identity fixture-next "A/B update" "$pv_user" "$pv_pass"
    else
        bad "the migrating slot never reached the post-commit release — the hold deadlocked the gate it was built not to"
        return 1
    fi
    if [ "$chain_ran_early" = 0 ]; then
        ok "monerod never ran while the slot was uncommitted"
    else
        bad "monerod ran BEFORE the commit — the migration would beat the fallback decision"
    fi
    if _ssh "journalctl -u pithead-boot -b | grep -q 'holding chain services'"; then
        ok "boot journal shows the chain hold"
    else
        bad "no 'holding chain services' line in the boot journal — the hold path never ran"
    fi
    # After the release: monerod back up, marker consumed.
    local mig_node_up=0
    for _ in $(seq 60); do
        if _ssh "podman ps --format '{{.Names}}' 2>/dev/null | grep -qx monerod"; then
            mig_node_up=1
            break
        fi
        sleep 5
    done
    if [ "$mig_node_up" = 1 ]; then
        ok "monerod is running again post-commit (the migration window is over)"
    else
        bad "monerod never came back after the commit"
    fi
    if _ssh "test -f /data/pithead/.os-migration-pending"; then
        bad "the migration-pending marker survived the commit"
    else
        ok "the migration-pending marker was consumed"
    fi
    phase_provision_floor_fallback_leg "$mig_bundle"
}
