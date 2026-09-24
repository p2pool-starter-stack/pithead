# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"

# ---- no room for the Tari migration (#2645): the migrating bundle is refused, nothing installed ----
# The staged data_migration bundle meets a /data filled to 1 GiB free, below the 5 GiB margin alone,
# so the local Tari node's data.mdb plus the margin cannot fit whatever its size. The refusal must
# leave both slots' RAUC records, the /data floor and the migration marker as they were. The filler
# then goes, and the caller's install below is the has-room case. The filler is fallocated on
# data.mdb's own filesystem, so no bytes are written; any leftover from an aborted run is removed.
# Returns 2 only when the filler is still there, the one failure the install below cannot survive.
_provision_migration_space_refusal() {
    local db mode mount fill rauc_before rauc_after floor_before out rc
    mode=$(_ssh "sed -n 's/^TARI_MODE=//p' /data/pithead/.env" | tr -d '\r')
    db=$(_ssh "cd /data/pithead && bash -c '. ./pithead && tari_local_db_file'" | tr -d '\r')
    if [ "$mode" != "local" ] || [ -z "$db" ]; then
        bad "the space refusal needs a local Tari node with a database to measure: TARI_MODE='$mode', data.mdb '${db:-none}'"
        return 1
    fi
    mount=$(_ssh "df -P '$db' | awk 'NR==2{print \$6}'" | tr -d '\r')
    fill="$mount/.pithead-space-fixture"
    _ssh "rm -f '$fill'"
    rauc_before=$(_ssh "rauc status --detailed --output-format=shell 2>/dev/null" |
        grep -E '^RAUC_(BOOT_PRIMARY|SLOT_STATUS_(BUNDLE_HASH|INSTALLED_TIMESTAMP|ACTIVATED_TIMESTAMP)_[0-9]+)=')
    floor_before=$(_ssh "cat /data/pithead/.os-data-floor 2>/dev/null" | tr -d ' \r\n')
    if [ -z "$rauc_before" ]; then
        bad "rauc status carried no slot records to compare — the refusal's 'nothing installed' cannot be checked"
        return 1
    fi
    if ! _ssh "a=\$(df -Pk '$mount' | awk 'NR==2{print \$4}') && fallocate -l \$((a - 1048576))K '$fill'"; then
        _ssh "rm -f '$fill'"
        bad "could not fill $mount to 1 GiB free for the space refusal"
        return 1
    fi
    out=$(_ssh "cd /data/pithead && ./pithead os-update /data/update.bundle --yes 2>&1")
    rc=$?
    _ssh "rm -f '$fill'"
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "Refusing: this update declares a chain data migration"; then
        ok "os-update refused the data_migration bundle with $mount at 1 GiB free (rc=$rc)"
    else
        bad "os-update did not refuse the data_migration bundle on a full $mount (rc=$rc): $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
        return 1
    fi
    if printf '%s' "$out" | grep -qE "GiB free on $mount \(Tari's data.mdb plus a 5 GiB margin\), and it has [01] GiB free"; then
        ok "the refusal names the volume, the size needed and the size free"
    else
        bad "the refusal does not name the volume, the size needed and the size free: $(printf '%s' "$out" | tail -1)"
    fi
    rauc_after=$(_ssh "rauc status --detailed --output-format=shell 2>/dev/null" |
        grep -E '^RAUC_(BOOT_PRIMARY|SLOT_STATUS_(BUNDLE_HASH|INSTALLED_TIMESTAMP|ACTIVATED_TIMESTAMP)_[0-9]+)=')
    if [ "$rauc_after" = "$rauc_before" ] && ! printf '%s' "$out" | grep -q "Installing OS update bundle"; then
        ok "nothing was installed: every slot's RAUC record is unchanged"
    else
        bad "the refused update changed a slot: RAUC records before/after differ or rauc install ran"
    fi
    if _ssh "test ! -e /data/pithead/.os-migration-pending" &&
        [ "$(_ssh "cat /data/pithead/.os-data-floor 2>/dev/null" | tr -d ' \r\n')" = "$floor_before" ]; then
        ok "the refusal left the /data floor (${floor_before:-none}) and the migration marker as they were"
    else
        bad "the refused update wrote the migration marker or moved the /data floor"
    fi
    if _ssh "test ! -e '$fill'"; then
        ok "the space fixture is gone; the install below is the has-room case"
    else
        bad "the space fixture could not be removed from $mount"
        return 2
    fi
}
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
        bundle_build_evidence
        bad "migration bundle build failed — read the build output above (/tmp/os-fault-bundle.log)"
        return 1
    }
    _stage_bundle "$mig_bundle" || {
        bad "staging the migration bundle failed"
        return 1
    }
    # Not gating: a failed sub-leg is its own row, and the install below still runs, unless the
    # filler is still on /data, where that install would be refused for the fixture's fault.
    _provision_migration_space_refusal
    [ "$?" -ne 2 ] || return 1
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
        # shellcheck disable=SC2154 # pv_user/pv_pass are set by the initial leg (phase-level locals).
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
