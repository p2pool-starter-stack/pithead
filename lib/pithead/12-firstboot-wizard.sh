firstboot_wizard() {
    local arg setup_rc preseed_restore_rc=0 spool="$PWD/data/firstboot" restore_spool
    restore_spool=$(restore_submission_dir)
    clear_legacy_wizard_snapshots "$spool" || error "Could not clear legacy private wizard snapshots."
    clear_legacy_wizard_snapshots "$restore_spool" || error "Could not clear temporary restore snapshots safely."
    clear_restore_stages || error "Could not clear temporary restore staging safely."
    wizard_clear_restore_state 0 "$spool" "$restore_spool" || error "Could not clear temporary restore handoff safely."
    clear_setup_candidate "$restore_spool/config.json" "$restore_spool/handoff.json" ||
        error "Could not clear temporary setup credentials safely."
    [ ! -f .restore-incomplete ] || error "The installed restore is incomplete. Run the installer restore again."
    for arg in "$@"; do
        case "$arg" in
        --cli) setup && return ;;
        --restore-pending)
            record_machine_role "$(machine_role_from_config "$PWD/config.json")"
            (setup) || {
                setup_rc=$?
                wizard_keep_failed_config || true
                return "$setup_rc"
            }
            control_consume_provisioning_marker "$PRESEED_DIR/pithead-setup-wizard" ||
                warn "Provisioning succeeded, but its setup-wizard history marker could not be recorded; it was kept for retry."
            return
            ;;
        *) error "Unknown option for firstboot-wizard: $arg. Run '$0 help'." ;;
        esac
    done
    # A rig install staged its answers on this ESP (the disk-install leg below): land them on
    # /data, the same one-move consumption as the config pre-seed — never on the installation
    # medium, where staged files are cleaned up by the installer itself. Then fall through to
    # the rig leg below, exactly as a pre-seeded coordinator falls through to setup.
    if [ -f "$PRESEED_DIR/pithead-rig.json" ] && ! installer_mode_available && [ ! -f "$PWD/rig.json" ]; then
        if jq -e 'type == "object" and ((.pool // "") | length > 0) and ((.access_token // "") | test("^[0-9a-f]{32}$"))' "$PRESEED_DIR/pithead-rig.json" >/dev/null 2>&1 &&
            install -m 600 "$PRESEED_DIR/pithead-rig.json" "$PWD/rig.json" 2>/dev/null; then
            record_machine_role rig
            scrub_staged_rig consumed # spent, and it may hold a stratum password
            _console "This machine is now a RigForge rig ($(jq -r '.worker // "unnamed"' "$PWD/rig.json" 2>/dev/null))."
        else
            warn "The staged rig settings at $PRESEED_DIR/pithead-rig.json are unusable — opening the setup page."
            scrub_staged_rig unusable # refused is still readable: same password, same bare ESP
        fi
    fi
    # A machine already carrying the rig role mines, and asks nothing — not even on a stick that
    # could offer the installer: a run-from-USB rig's stick IS that rig's system, not a fleet tool.
    # Reached only on the boot that ACCEPTS the role (a disk install's first boot, just above); a
    # boot from the menu's "Set up again" entry (#1318) skips this and opens the page beside the role.
    # The miner is best-effort, as in pithead-boot: a pool that moved must not brick the boot.
    if [ "$(machine_role)" = "rig" ] && ! setup_again_mode; then
        _console "This machine is a RigForge rig ($(jq -r '.worker // "unnamed"' "$PWD/rig.json" 2>/dev/null) -> $(jq -r '.pool // "no pool recorded"' "$PWD/rig.json" 2>/dev/null))."
        provision_rig_miner || true
        return 0
    fi
    # A configuration dropped on the medium beats opening a browser at all — but never on the
    # INSTALLATION medium: pre-seeding covers configuration, not the erase decision (the docs'
    # exact promise), and a fleet stick that provisioned ITSELF instead of offering the
    # installer would burn out running a chain it can never hold. There, the pre-seed becomes
    # the pre-filled combined page instead (below).
    if ! installer_mode_available; then
        # The carried restore first: it holds MORE than a config (keys, database), and once it
        # lands the config pre-seed guard below sees config.json and stands down. Unconditional —
        # gating on config.json's own absence let a `wipe=keep` target's PRIOR config.json skip
        # the carried restore entirely (#2195); consume_preseed_restore itself no-ops (rc 2 idle).
        # rc 3 means its temporary secrets could not be cleared: stop rather than run on beside them.
        consume_preseed_restore || preseed_restore_rc=$?
        [ "$preseed_restore_rc" -ne 3 ] || error "Could not clear temporary restore files safely — reboot before continuing."
        if [ ! -f "$PWD/config.json" ] && consume_preseed_config "$PWD/config.json"; then
            # Spent: config.json lives on /data now, and a plaintext wallet + password must not
            # sit on this machine's unencrypted ESP forever. Only on an INSTALLED machine —
            # running from removable media this is the operator's own stick, theirs to keep
            # for the next machine in the fleet.
            if ! boot_is_removable; then
                mount -o remount,rw "$PRESEED_DIR" 2>/dev/null || true
                rm -f "$PRESEED_DIR/pithead-config.json" 2>/dev/null ||
                    warn "Could not remove the consumed pre-seed from $PRESEED_DIR — it holds credentials; delete it."
            fi
        fi
        if [ -f "$PWD/config.json" ] && ! setup_again_mode; then
            log "config.json already present (pre-seeded) — skipping the wizard and running setup."
            # A pre-seeded config that names no password still gets a login.
            ensure_appliance_dashboard_password || true
            apply_appliance_defaults || true
            record_machine_role "$(machine_role_from_config "$PWD/config.json")"
            setup
            control_consume_provisioning_marker "$PRESEED_DIR/pithead-setup-wizard" ||
                warn "Provisioning succeeded, but its setup-wizard history marker could not be recorded; it was kept for retry."
            return
        fi
    fi
    _console "" "Pithead is starting up — preparing the setup page." \
        "This takes a minute or two on first boot. Nothing to do yet."

    local engine image token
    engine=$(container_engine)
    # STACK_VERSION is the ONE place the registry tag is derived (a release is v<VERSION>, a
    # source checkout is dev) — deriving it here instead cost a boot: the archive holds
    # :vX.Y.Z while a hand-rolled ":$VERSION" looks for a tag that was never published.
    export_build_provenance
    image="${PITHEAD_REGISTRY}/pithead-dashboard:${STACK_VERSION}"
    stage_wizard_spool "$spool" >/dev/null || error "Could not prepare the setup page files."
    prepare_wizard_spool "$restore_spool" || error "Could not prepare private restore submission storage."

    local installer=0 operator_preseed=0 candidate="$PWD/config.json" card_spool="$spool" card_mount=/wizard-spool
    [ -f "$PRESEED_DIR/pithead-config.json" ] && operator_preseed=1
    if installer_mode_available; then
        installer=1 # the disk list is staged with the rest of the spool, every session
        candidate="$restore_spool/config.json"
        card_spool="$restore_spool"
        card_mount=/wizard-restore
        log "Running from the installation medium — install and configure on one page."
        # The pre-fill is derived fresh every boot, never inherited: the stick's spool
        # survives between machines, and machine 2 must not open on machine 1's answers —
        # the same staleness rule the per-session flow-marker clear below enforces.
        rm -f "$spool/last-attempt.json" "$spool/install-attempt.json" \
            "$spool/auth-mode" "$spool/config-changes.json" "$spool/setup-failed"
        wizard_clear_submission_transaction "$spool" || error "Could not clear the previous setup transaction."
        if [ "$operator_preseed" -eq 1 ] && wizard_spool_publish "$spool" last-attempt.json jq -c . "$PRESEED_DIR/pithead-config.json" 2>/dev/null; then
            log "Pre-seeded configuration found — the page opens with it filled in."
        elif prefill_from_previous_install "$spool"; then
            log "Found the previous installation's settings on the target disk — the page opens with them filled in (secrets left out)."
        fi
    elif boot_is_removable; then
        # Setup will proceed, but the operator should know what they are standing on: a USB stick
        # cannot hold a 250+ GB chain and wears out under constant writes.
        warn "Booted from removable media with no internal disk to install onto."
        warn "Running the stack from a USB stick is unsupported — it is too slow for the chain and the stick will wear out."
    fi
    # Offline first boot: the appliance carries the wizard image as an archive (os/rootfs/images),
    # because at this point the operator may have no working network yet — that is what they are
    # here to configure. The loader is the boot path's own (see load_baked_images): naming the
    # image forces a load when the tag is missing entirely, whatever the digest record says.
    load_baked_images "$image"
    # Double quotes on purpose: $engine expands NOW, at trap definition. It is a local, and the
    # trap also fires after this function's locals are gone — where set -u would turn the trap
    # itself into the crash that masks whatever actually failed. The spool paths expand now for
    # the same reason, so the trap can still clear this session's restore and setup secrets.
    local cert_fp=""

    # shellcheck disable=SC2064  # expand-now is the point (see above)
    trap "'$engine' rm -f pithead-wizard >/dev/null 2>&1 || true; clear_restore_submission '$spool' '$restore_spool' || true; clear_setup_candidate '$restore_spool/config.json' '$restore_spool/handoff.json' || true; clear_restore_carry || true" EXIT
    while :; do
        # Re-stage per session, and re-derive the fingerprint with it: the accept path removes the
        # spool, so a retry that reused a cert_fp computed once would advertise HTTPS and a
        # fingerprint for a certificate the container can no longer read (#1063).
        cert_fp=$(stage_wizard_spool "$spool") || error "Could not prepare the setup page files."
        [ -n "$cert_fp" ] || warn "Could not generate a setup certificate — the setup page will be plain HTTP."
        # Every wizard session starts with CLEAN flow state. The spool lives on this medium's
        # /data, which survives reboots — so a fleet stick that installed machine 1 still
        # carries its handoff.json, ack and installed markers, and machine 2's boot would open
        # on the switch-off page with machine 1's stale credentials card still answering.
        # error.txt and last-attempt.json survive on purpose: they are the retry context the
        # failed-provisioning path just wrote for the reopened page. The restore passphrase and
        # an installer's config candidate live in the volatile restore spool and go every round.
        rm -f "$spool/handoff.json" "$spool/handoff-ack" "$spool/installing" \
            "$spool/installed" "$spool/applied" "$spool/install-request" \
            "$spool/rig-request.json" "$spool/role" \
            "$spool/keep-role" "$spool/stick"
        wizard_clear_submission_transaction "$spool" || error "Could not clear the previous setup transaction."
        clear_restore_submission "$spool" "$restore_spool" || error "Could not clear the previous restore submission."
        clear_setup_candidate "$restore_spool/config.json" "$restore_spool/handoff.json" || error "Could not clear private setup credentials."
        # Keep an operator's pre-seeded token; otherwise mint a fresh one every round.
        token=$(preseed_token) || token=$(wizard_mint_token)
        "$engine" rm -f pithead-wizard >/dev/null 2>&1 || true
        "$engine" run -d --name pithead-wizard --entrypoint python3 \
            -p 80:8000 -p 443:8443 -e WIZARD_TOKEN="$token" \
            -e WIZARD_TLS_CERT="${cert_fp:+/wizard-spool/wizard.crt}" \
            -e WIZARD_TLS_KEY="${cert_fp:+/wizard-spool/wizard.key}" \
            -e WIZARD_RESTORE=/wizard-restore \
            -e TMPDIR=/wizard-restore \
            -e WIZARD_HANDOFF="$card_mount" \
            -v "$spool":/wizard-spool -v "$restore_spool":/wizard-restore \
            "$image" -m mining_dashboard.wizard >/dev/null || {
            # `error` writes to stderr = /dev/console, ONE device (whichever the cmdline named
            # LAST); on a box whose monitor is the other one the failure is invisible and a STOPPED
            # box reads as a slow one — a three-minute failure was once taken for an hour of
            # progress. _console reaches every physical console, which is the whole point here.
            _console "" "Setup has STOPPED — this box is no longer preparing a page." \
                "The container engine could not start the setup page." \
                "Diagnose with: journalctl -u pithead-firstboot -b"
            error "Could not start the wizard container ($engine, $image). Pre-seed config.json or run '$0 firstboot-wizard --cli'."
        }
        local mdns_name scheme
        mdns_name="$(hostname).local"
        scheme="http"
        [ -n "$cert_fp" ] && scheme="https"
        log "Setup wizard is up. From a browser on this network, open:"
        log "    $scheme://$mdns_name"
        for arg in $(hostname -I 2>/dev/null || echo 127.0.0.1); do log "    $scheme://$arg"; done
        log "One-time token: $token"
        # Announce on every physical console, not just stdout. /dev/console is whichever the
        # kernel cmdline named LAST, so an operator watching the other one (a monitor when the
        # box also has a serial line, or vice versa) would otherwise never see the token.
        # The mDNS name FIRST: it is what the documentation tells operators to use, it survives a
        # DHCP lease change, and it is the only address that still works once the monitor is gone.
        # The IP follows as the fallback for networks where mDNS is filtered.
        for dev in /dev/tty1 /dev/ttyS0; do
            [ -w "$dev" ] || continue
            {
                echo ""
                echo "  Pithead setup wizard is ready. From a browser on this network, open:"
                echo "      $scheme://$mdns_name"
                echo "      $scheme://$(hostname -I 2>/dev/null | awk '{print $1}')   (if the name above does not resolve)"
                echo ""
                echo "  One-time token: $token"
                echo "  (case does not matter, and the pit- prefix is optional)"
                if [ -n "$cert_fp" ]; then
                    echo ""
                    echo "  Your browser will warn that the certificate is not trusted. That is expected:"
                    echo "  this machine signed its own. Check it matches before continuing --"
                    echo "  SHA-256: $cert_fp"
                fi
                echo ""
            } >"$dev" 2>/dev/null || true
        done
        while :; do
            # #1318 "Keep it": the page wrote keep-role — nothing on /data was touched; return.
            wizard_keep_requested "$spool" && return 0
            # A keep-everything reinstall arrives as a bare install-request with no config
            # candidate: the preserved /data keeps config, login and chains, so there is
            # nothing to validate and no credentials to hand off — install and switch off.
            # BARE means bare: a staged restore archive (#909) rides the same install-request
            # with keep as its erase policy (restore the config, keep the synced chains), and
            # this shortcut once swallowed it — the machine "keep"-installed a blank disk and
            # the operator's backup never reached it. The archive must be consumed first, and
            # the checks cover the volatile restore spool as well as the persistent one.
            if [ "$installer" -eq 1 ] && wizard_submission_ready "$spool" &&
                wizard_spool_has "$spool" install-request &&
                [ "$(wizard_spool_read "$spool" install-request 2>/dev/null | cut -f2)" = "keep" ] &&
                [ ! -e "$spool/config.json" ] && [ ! -L "$spool/config.json" ] &&
                [ ! -e "$restore_spool/restore-passphrase" ] && [ ! -L "$restore_spool/restore-passphrase" ] &&
                [ ! -e "$restore_spool/restore-archive" ] && [ ! -L "$restore_spool/restore-archive" ] &&
                [ ! -e "$spool/restore-archive" ] && [ ! -L "$spool/restore-archive" ]; then
                wizard_install_begin "$spool"
                local irc=0
                consume_install_request "$spool" keep || irc=$?
                if [ "$irc" -ne 0 ]; then
                    rm -f "$spool/installing"
                    wizard_install_failed_page "$spool" "Reinstall" || return 1
                    continue
                fi
                wizard_install_finish "$engine" "$spool" "Reinstall complete — switching off now." "Everything it knew — settings, wallets, login, chains — is still there."
                return
            fi
            # The rig role's submission travels on its own channel — no pithead config exists
            # to validate. Same discipline, different shape: dial the pool BEFORE anything
            # irreversible, card before commitment, the ack releases the erase.
            local rrc=0
            firstboot_consume_rig "$spool" || rrc=$?
            if [ "$rrc" -eq 1 ]; then
                warn "Rig settings rejected — the page shows the reason."
                sleep 2
                continue
            fi
            if [ "$rrc" -eq 0 ]; then
                log "Rig settings accepted."
                local rig_worker rig_pool rig_token
                rig_worker=$(jq -r '.worker // ""' "$PWD/rig.json" 2>/dev/null)
                rig_pool=$(jq -r '.pool // ""' "$PWD/rig.json" 2>/dev/null)
                rig_token=$(rig_access_token) || rig_token="" # empty here = the render leg refuses below
                # The rig's card: worker, pool, the control token (#1836 — minted once, shown ONCE, no login) and
                # this box's address; an unresolvable pool host (#1867) adds control:"off" and why instead.
                jq -n --arg w "$rig_worker" --arg s "stratum+tcp://$rig_pool" --arg t "$rig_token" --arg a "$(hostname -I 2>/dev/null | awk '{print $1}')" --arg allow "$(rig_coordinator_ip)" \
                    --arg reason "the pool host does not resolve to an IPv4 address to pin it to" '{role: "rig", worker: $w, stratum: $s, token: $t, address: $a} + (if $allow == "" then {control: "off", reason: $reason} else {} end)' | write_handoff_card "$card_spool"
                local hwait=0
                while ! wizard_spool_has "$spool" handoff-ack && [ "$hwait" -lt 600 ]; do
                    sleep 2
                    hwait=$((hwait + 2))
                done
                if [ "$installer" -eq 1 ] && wizard_spool_has "$spool" install-request; then
                    # Rig onto a disk: identical erase discipline to the coordinator install —
                    # the ack releases it, and a missing human hands the form back intact.
                    if ! wizard_spool_has "$spool" handoff-ack; then
                        clear_setup_candidate "$card_spool/handoff.json" || true
                        rm -f "$spool/install-request" "$PWD/rig.json"
                        printf 'The rig card was never confirmed — nothing was installed. Submit again when you are ready.' | wizard_spool_publish "$spool" error.txt cat
                        wizard_clear_submission_transaction "$spool" || return 1
                        continue
                    fi
                    wizard_install_begin "$spool"
                    # Stage the accepted settings onto the running ESP: the installer carries
                    # them to the target's ESP, and the first boot from disk lands them on its
                    # /data (the top of this function). The stick keeps NEITHER copy — rig.json
                    # on its /data would turn the stick itself into a rig at the next boot, and
                    # a leftover ESP file would seed every later machine.
                    mount -o remount,rw /boot/efi 2>/dev/null || true
                    if ! install -m 600 "$PWD/rig.json" /boot/efi/pithead-rig.json; then
                        rm -f "$spool/installing" "$spool/handoff.json" "$spool/handoff-ack" "$spool/install-request" "$PWD/rig.json"
                        printf 'Could not stage the rig settings for the installed system — nothing was installed.' | wizard_spool_publish "$spool" error.txt cat
                        wizard_clear_submission_transaction "$spool" || return 1
                        mutation_lock_release
                        continue
                    fi
                    local irc=0
                    consume_install_request "$spool" || irc=$?
                    rm -f "$PWD/rig.json" /boot/efi/pithead-rig.json
                    if [ "$irc" -ne 0 ]; then
                        rm -f "$spool/installing" "$spool/handoff.json" "$spool/handoff-ack"
                        wizard_install_failed_page "$spool" "Install" || return 1
                        continue
                    fi
                    wizard_install_finish "$engine" "$spool" "Installation complete — switching off now." "It will come up as the rig you just confirmed."
                    return
                fi
                # Run from this medium — or an installed machine choosing the rig role: the
                # answers stay on THIS machine's /data and the marker closes the wizard window.
                record_machine_role rig
                wizard_spool_publish "$spool" applied true
                sleep 8 # long enough for the page's poll to show the saved state
                "$engine" rm -f pithead-wizard >/dev/null 2>&1 || true
                wizard_clear_submission_transaction "$spool" || return 1
                _console "Rig settings saved: $rig_worker -> stratum+tcp://$rig_pool."
                # Mine now, on this boot. Every later boot goes through pithead-boot, whose own
                # condition now covers the marker just written — there is no second wizard and no
                # reboot to wait for, the same way an accepted coordinator config runs setup here.
                provision_rig_miner || true
                return 0
            fi
            # The restore-from-backup alternative (#909) travels its own spool channel, same as
            # the rig role above — but on acceptance it has ALREADY written the config candidate
            # and touched applied (firstboot_consume_restore does the whole job, staged through a
            # copy), so a successful restore short-circuits straight into the identical accept
            # path a typed submission takes, below. rc 3 means its temporary secrets could not be
            # cleared: stop this boot rather than serve the page again beside them.
            local rec=0
            firstboot_consume_restore "$spool" "$installer" "$restore_spool" "$candidate" || rec=$?
            [ "$rec" -ne 3 ] || error "Could not clear temporary restore credentials safely — reboot before continuing."
            if [ "$rec" -eq 1 ]; then
                # The install-request goes back too: with the archive gone, leaving it staged
                # would let the bare-keep shortcut above fire on the next pass — a typo'd
                # passphrase must hand the form back, never quietly install without the restore.
                rm -f "$spool/install-request"
                [ "$installer" -ne 1 ] || clear_setup_candidate "$candidate" || return 1
                wizard_clear_restore_state "$rec" "$spool" "$restore_spool" || return 1
                warn "Restore rejected — the page shows the reason."
                sleep 2
                continue
            fi
            if [ "$rec" -eq 0 ] || firstboot_consume_spool "$spool" "$candidate"; then
                # Reachability before commitment: a remote node that cannot be dialed fails HERE,
                # on the page, with the attempt kept for editing — not minutes into provisioning.
                local pf_err
                if ! pf_err=$(preflight_remote_nodes "$candidate"); then
                    printf '%s' "$pf_err" | tail -c 300 | wizard_spool_publish "$spool" error.txt cat
                    wizard_publish_retry_config "$spool" "$candidate" "$installer" 2>/dev/null
                    # Same bare-keep hazard as a rejected restore: the config candidate is gone,
                    # so a staged keep install-request would install WITHOUT it on the next pass.
                    clear_setup_candidate "$candidate" || true
                    rm -f "$spool/install-request"
                    wizard_clear_restore_state "$rec" "$spool" "$restore_spool" || return 1
                    warn "Preflight failed: $pf_err"
                    sleep 2
                    continue
                fi
                log "Configuration accepted — provisioning now."
                ensure_appliance_dashboard_password "$spool" "$candidate" || true
                apply_appliance_defaults "$candidate" || true
                # The candidate was validated BEFORE those two ran, so until #1066 the config the
                # operator was told had been accepted was not the config about to be provisioned.
                # Validate what actually lands: anything the appliance itself injects has to pass
                # the same gate, and a collision must hand the form back HERE — while the page is
                # still up — rather than fail after it has gone dark.
                local post_err
                # Same isolation the other two validator calls use: a fresh bash so the
                # validator's own error() exit cannot take this loop with it, and CONFIG_FILE
                # (readonly) is aimed by the env var rather than reassigned.
                if ! post_err=$(PITHEAD_CONFIG_FILE="$candidate" PITHEAD_CONFIG_SET=1 bash -c "source '${BASH_SOURCE[0]}' && parse_and_validate_config" 2>&1); then
                    printf '%s' "$post_err" | tail -c 300 | wizard_spool_publish "$spool" error.txt cat
                    wizard_publish_retry_config "$spool" "$candidate" "$installer" 2>/dev/null
                    clear_setup_candidate "$candidate" "${candidate}.bak-1x" || true
                    rm -f "$spool/install-request"
                    wizard_clear_restore_state "$rec" "$spool" "$restore_spool" || return 1
                    warn "The configuration this machine assembled did not pass validation: $post_err"
                    sleep 2
                    continue
                fi
                # Rename BEFORE the handoff below (#2350): `(setup)` further down applied it too
                # late — after the operator had already seen and acked the card naming the OLD box.
                local DASHBOARD_HOST stratum_addr dash_user dash_pass
                DASHBOARD_HOST=$(resolve_default "$(jq -r '.dashboard.host // empty' "$candidate" 2>/dev/null)" "")
                reconcile_appliance_hostname
                stratum_addr="stratum+tcp://$(hostname).local:$(jq -r '.p2pool.stratum_port // 3333' "$candidate" 2>/dev/null || echo 3333)"
                dash_user=$(jq -r '.dashboard.auth.username // "admin"' "$candidate")
                dash_pass=$(jq -r '.dashboard.auth.password // ""' "$candidate")
                _console "" "Point your miners at this machine:" "    $stratum_addr"
                # The handoff: credentials and addresses ON THE PAGE, over the same TLS the
                # operator just typed secrets into — a 32-character random password transcribed
                # from a console was never realistic. Provisioning holds until they confirm
                # they saved it (or 10 minutes pass — an unattended pre-seeded run must not
                # hang forever), because the page goes DARK during provisioning and the
                # credentials must not vanish with it.
                jq -n --arg u "$dash_user" --arg p "$dash_pass" \
                    --arg d "https://$(hostname).local" --arg s "$stratum_addr" \
                    '{username:$u,password:$p,dashboard:$d,stratum:$s}' | write_handoff_card "$card_spool"
                local hwait=0
                while ! wizard_spool_has "$spool" handoff-ack && [ "$hwait" -lt 600 ]; do
                    sleep 2
                    hwait=$((hwait + 2))
                done
                if [ "$installer" -eq 1 ]; then
                    # Combined install+configure (one page on the USB). The ack releases the
                    # ERASE, so a missing human means no install: hand the form back intact
                    # rather than destroy a disk on a timeout.
                    if ! wizard_spool_has "$spool" handoff-ack; then
                        rm -f "$spool/handoff.json" "$spool/install-request"
                        printf 'Credentials were never confirmed — nothing was installed. Submit again when you are ready.' | wizard_spool_publish "$spool" error.txt cat
                        wizard_publish_retry_config "$spool" "$candidate" "$installer" 2>/dev/null
                        clear_setup_candidate "$candidate" "$card_spool/handoff.json" || true
                        wizard_clear_restore_state "$rec" "$spool" "$restore_spool" || return 1
                        continue
                    fi
                    wizard_install_begin "$spool"
                    # Stage the accepted config onto the ESP; the installer carries it to the target.
                    # A fleet stick's own pre-seed is set aside first and restored after: the
                    # accepted config carries THIS machine's generated password, and leaving it
                    # on the stick would hand every later machine the first one's secrets.
                    # An accepted RESTORE never touches the ESP: its archive and passphrase stay
                    # in root-owned volatile storage, the installer runs with --no-preseeds (so
                    # the fleet pre-seed stays where it is), and the restore is applied straight
                    # onto the target's /data before it ever boots (install_restore_to_target).
                    local preseed_orig=""
                    if [ "$operator_preseed" -eq 1 ] && [ "$rec" -ne 0 ]; then
                        if ! preseed_orig=$(mktemp) || ! cp /boot/efi/pithead-config.json "$preseed_orig" 2>/dev/null; then
                            [ -z "$preseed_orig" ] || rm -f "$preseed_orig" 2>/dev/null || true
                            wizard_spool_publish "$spool" error.txt printf '%s' 'Could not preserve the installer pre-seed safely.' || true
                            clear_setup_candidate "$candidate" "$card_spool/handoff.json" || true
                            wizard_clear_restore_state "$rec" "$spool" "$restore_spool" || true
                            mutation_lock_release
                            return 1
                        fi
                    fi
                    mount -o remount,rw /boot/efi 2>/dev/null || true
                    local carry staged_ok=1
                    carry=$(restore_carry_dir)
                    if [ ! -f "$carry/archive" ]; then
                        install -m 600 "$candidate" /boot/efi/pithead-config.json || staged_ok=0
                    fi
                    install -m 600 /dev/null /boot/efi/pithead-setup-wizard || staged_ok=0
                    if [ "$staged_ok" -ne 1 ]; then
                        rm -f "$spool/installing" "$spool/handoff.json" "$spool/handoff-ack" "$spool/install-request"
                        printf 'Could not stage the configuration for the installed system — nothing was installed.' | wizard_spool_publish "$spool" error.txt cat
                        local staging_cleanup=0
                        wizard_cleanup_installer_credentials "$preseed_orig" "$candidate" "$card_spool/handoff.json" "$rec" "$spool" "$restore_spool" "$carry" || staging_cleanup=1
                        mutation_lock_release
                        if [ "$staging_cleanup" -ne 0 ]; then
                            wizard_spool_publish "$spool" error.txt printf '%s' 'Temporary installer credentials could not be cleared safely.' || true
                            return 1
                        fi
                        continue
                    fi
                    local irc=0 cleanup_failed=0
                    consume_install_request "$spool" "" "$carry" "$candidate" || irc=$?
                    # The stick must not keep the accepted config: a stick with config.json
                    # boots as a PROVISIONING host next time instead of an installer.
                    # The stick's ESP gets its ORIGINAL back (fleet stick) or comes up clean:
                    # either way the staged copy — with this machine's password — never rides on.
                    # The restore passphrase and archive go with it, success or not.
                    if ! wizard_cleanup_installer_credentials "$preseed_orig" "$candidate" "$card_spool/handoff.json" "$rec" "$spool" "$restore_spool" "$carry"; then
                        wizard_spool_publish "$spool" error.txt printf '%s' 'Installation completed, but temporary installer credentials could not be cleared safely.'
                        cleanup_failed=1
                        irc=1
                    fi
                    if [ "$irc" -ne 0 ]; then
                        rm -f "$spool/installing" "$spool/handoff.json" "$spool/handoff-ack"
                        wizard_spool_has "$spool" last-attempt.json || true
                        wizard_install_failed_page "$spool" "Install" || return 1
                        [ "$cleanup_failed" = 0 ] || return 1
                        continue
                    fi
                    wizard_install_finish "$engine" "$spool" "Installation complete — switching off now." "It will provision itself with the configuration you just confirmed."
                    return
                fi
                # Installed machine: its accepted role lands here, not on the installer path.
                record_machine_role "$(machine_role_from_config "$PWD/config.json")"
                sleep 2
                "$engine" rm -f pithead-wizard >/dev/null 2>&1 || true
                rm -rf "$spool"
                # Subshell on purpose: error() exits. Without this, config.json exists, the wizard's condition
                # never re-arms, and a box with no shell has no recovery path at all. Output is
                # teed: the console keeps its live narration, and the tail becomes the reopened
                # page's error — a refusal that lives only in console scrollback cost a bench
                # session an hour of believing the machine had crashed.
                local setup_log setup_rc=0
                setup_log=$(mktemp)
                # The STATUS is captured, not just its truthiness: `if (setup) | tee` collapses
                # every failure to one, and a lock timeout (PITHEAD_EX_LOCK_TIMEOUT) has to be
                # told apart from a bad configuration — see wizard_setup_failed. PIPESTATUS is not
                # needed here because `pipefail` is set, so the pipeline carries setup's own
                # non-zero status; `|| setup_rc=$?` is what keeps `set -e` from taking the branch
                # away before it can be read.
                { (setup) 2>&1 | tee "$setup_log"; } || setup_rc=$?
                if [ "$setup_rc" -eq 0 ]; then
                    if control_audit_provisioned "$PWD/data/control"; then
                        rm -f "$setup_log"
                        return
                    fi
                    printf '[ERROR] Provisioning finished, but its setup history could not be recorded. Retry to complete setup history safely.\n' >>"$setup_log"
                    setup_rc=1
                fi
                # The machine KEEPS its configuration (#1059) — this used to move it aside, which
                # on this path can only cost. The reasoning, and why the removal that remains is
                # conditional, is at wizard_keep_failed_config's definition and wizard_setup_failed.
                local kept_copy=0
                if wizard_setup_failed "$setup_rc"; then kept_copy=1; fi
                prepare_wizard_spool "$spool" || return 1
                # The reopened page gets BOTH halves of a usable retry: the reason it failed, and
                # the configuration that failed — nobody re-pastes a 95-character address the
                # machine still holds. The accept path wiped the spool, so both are restored here.
                grep -a "\[ERROR\]" "$setup_log" | tail -n 1 | tr -d '[:cntrl:]' | tail -c 300 | wizard_spool_publish "$spool" error.txt cat
                [ -n "$(wizard_spool_read "$spool" error.txt)" ] || printf 'Provisioning failed — see the machine console for detail.' | wizard_spool_publish "$spool" error.txt cat
                wizard_spool_publish "$spool" setup-failed true || return 1
                # Prefill from what THIS run failed on. The copy when it was made, the live file
                # otherwise — never a config.json.failed left by an earlier attempt, which would
                # hand the operator back answers they had already moved past.
                if [ "$kept_copy" -eq 1 ]; then
                    wizard_spool_publish "$spool" last-attempt.json jq -c . "$PWD/config.json.failed" 2>/dev/null || true
                elif [ -f "$PWD/config.json" ]; then
                    wizard_spool_publish "$spool" last-attempt.json jq -c . "$PWD/config.json" 2>/dev/null || true
                fi
                rm -f "$setup_log"
                break # outer loop re-mints a token and restarts the wizard container
            fi
            if ! "$engine" inspect -f '{{.State.Running}}' pithead-wizard 2>/dev/null | grep -q true; then
                warn "Wizard stopped (token lockout or crash) — minting a fresh token and restarting it."
                break
            fi
            sleep 2
        done
    done
}
