# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"

# Cross-version update (#2056): the `update` phase's legs build BOTH A/B slots from THIS tree
# with different markers, so they prove the updater mechanism (the A/B swap, the commit decision,
# rollback, identity survival) but nothing that only differs between two real releases — a
# config/state schema migration, a unit added/renamed/removed, a /data layout change, or a
# `pithead` CLI change that assumes on-disk state an older version never wrote. This phase starts
# from a REAL prior build instead of the same tree: bench-ci's tier4-kvm `options.old_image: true`
# resolves the newest appliance image cached for a commit strictly older than the one under test
# (a nightly `develop` run leaves one behind every day) and hands it here as $PITHEAD_OLD_IMAGE,
# alongside the candidate this job already built for its own commit. Once 2.0.0 exists, the old
# slot becomes the published release image instead — see docs/dev/testing-strategy.md.
#
# Deliberately NOT in the `all` arm below: it needs $PITHEAD_OLD_IMAGE, which only a job that
# requested `options.old_image: true` carries: an `all` run wants every phase to work from the
# image it was given alone.
phase_crossupdate() {
    info "phase: crossupdate (a provisioned N-1 guest upgraded to the candidate built from HEAD)"
    local old="${PITHEAD_OLD_IMAGE:-}"
    [ -n "$old" ] && [ -f "$old" ] || {
        bad "PITHEAD_OLD_IMAGE not set or not a file — this phase needs bench-ci's tier4-kvm options.old_image (docs/dev/testing-strategy.md)"
        return
    }

    info "booting the old appliance image ($old)"
    _vm_boot_disk "$old" && _wait_ssh 900 || {
        bad "the old-version guest never answered SSH (ip: ${ip:-none}; $(_ssh_unreachable_reason "$ip"))"
        return
    }
    ok "old-version guest boots and answers SSH ($ip)"

    info "provisioning the old-version guest through its real wizard"
    _wizard_provision_capture 0 || {
        bad "provisioning the old-version guest failed ($WIZ_FAIL_REASON)"
        return
    }
    ok "old-version guest provisioned (dashboard login captured)"
    local old_user="$DASH_USER" old_pass="$DASH_PASS"

    local deadline=$(($(date +%s) + 1500)) names=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        names=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
        sleep 15
    done
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*) ok "old-version stack containers are running" ;;
    *)
        bad "old-version stack never came up — running: '${names:-none}'"
        return
        ;;
    esac

    local id_old hostkey_fp_old
    id_old=$(_ssh cat /etc/machine-id)
    hostkey_fp_old=$(_ssh ssh-keygen -lf /data/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $2}')
    if _ssh "grep -q \"$HARNESS_WALLET\" /data/pithead/config.json"; then
        ok "old-version config carries the submitted wallet"
    else
        bad "old-version config does not carry the submitted wallet"
    fi

    info "building the candidate update bundle from the commit under test"
    local bundle
    bundle=$(_build_bundle candidate) || {
        bundle_build_evidence
        bad "candidate bundle build failed (/tmp/os-fault-bundle.log)"
        return
    }
    ok "built candidate bundle: $(basename "$bundle")"

    _stage_bundle "$bundle" || {
        bad "staging the candidate bundle on the old-version guest failed"
        return
    }
    local out rc
    out=$(_ssh "$(_install_cmd /data/update.bundle) 2>&1")
    rc=$?
    [ -n "$out" ] && printf '     install output: %s\n' "$(printf '%s' "$out" | tail -5)"
    [ "$rc" -eq 0 ] || {
        bad "installing the candidate onto the old-version guest failed"
        return
    }
    ok "candidate installed into the spare slot"

    _reboot_wait "$(_boot_spare_cmd)" 300 || {
        bad "guest never returned after booting the candidate slot"
        return
    }
    _ssh "$(_commit_cmd)" || {
        bad "commit failed ($(_commit_cmd))"
        return
    }
    ok "committed the cross-version update"
    _reboot_wait reboot 300 || {
        bad "guest never returned after the post-commit reboot"
        return
    }
    _wait_ssh 240 || {
        bad "guest SSH never came back after the cross-version update ($(_ssh_unreachable_reason "$ip"))"
        return
    }

    local marker
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "candidate" ] && ok "the candidate slot is booted (marker: candidate)" ||
        bad "expected the candidate marker after the update, got '${marker:-none}'"

    local id_new hostkey_fp_new
    id_new=$(_ssh cat /etc/machine-id)
    hostkey_fp_new=$(_ssh ssh-keygen -lf /data/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $2}')
    if [ -n "$id_old" ] && [ "$id_old" = "$id_new" ]; then
        ok "machine-id survived the cross-version update ($id_old)"
    else
        bad "machine-id changed across the cross-version update (old: ${id_old:-none}, new: ${id_new:-none})"
    fi
    if [ -n "$hostkey_fp_old" ] && [ "$hostkey_fp_old" = "$hostkey_fp_new" ]; then
        ok "SSH host-key fingerprint survived the cross-version update ($hostkey_fp_old)"
    else
        bad "SSH host-key fingerprint changed across the cross-version update (old: ${hostkey_fp_old:-none}, new: ${hostkey_fp_new:-none})"
    fi

    if _ssh "grep -q \"$HARNESS_WALLET\" /data/pithead/config.json"; then
        ok "the old version's provisioned config is still honoured after the update"
    else
        bad "the old version's provisioned config did not survive the update"
    fi

    # Transient healthcheck ephemera excluded, same as the reboot leg's check (provision-reboot.sh):
    # podman drives container healthchecks through hash-named systemd-run units, and one dies
    # harmlessly whenever compose recreates its container mid-check.
    local failed_units
    failed_units=$(_ssh "systemctl --failed --no-legend --no-pager --plain" 2>/dev/null |
        awk '$1 !~ /^[0-9a-f]{64}-[0-9a-f]+\.service$/' | tr -s ' ' | tr '\n' ';')
    if [ -z "${failed_units//[; ]/}" ]; then
        ok "no unit left failed after the cross-version update"
    else
        bad "unit(s) failed after the cross-version update: $failed_units"
    fi

    local dm
    if dm=$(_dash_marker_served candidate 360); then
        ok "the candidate dashboard image is what's actually serving after the update"
    else
        bad "the OS updated but the old dashboard image is still serving (got: $dm)"
    fi

    local scode
    scode=$(curl -sSk -u "$old_user:$old_pass" -m 8 -o /dev/null -w '%{http_code}' "https://$ip/api/state" 2>/dev/null)
    [ "$scode" = "200" ] && ok "the dashboard login minted by the old version still authenticates after the update" ||
        bad "the old version's dashboard login no longer authenticates after the update (got HTTP $scode)"
}
