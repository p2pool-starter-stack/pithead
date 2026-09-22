# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# leg 5 — a container whose OWN healthcheck fails must hold the gate (#2383, manual battery M9).
# Split from phases/update.sh (file-budget ratchet): called from phase_update right after
# phase_update_dashboard, on the same provisioned, committed guest leg 4 left behind.
#
# M9 on the HP appliance: a dev bundle whose dashboard healthcheck was replaced with `exit 1`
# committed anyway — the dashboard container ran and answered HTTP, doctor only judges the
# revenue containers (monerod/p2pool/tari), and nothing on the boot path read container health at
# all. This leg reproduces exactly that shape, and needs leg 4's provisioned, committed guest
# (pithead-boot.service is conditioned on config.json/machine-role, neither of which legs 1-3 ever
# write — see phase_update's #2055 G1 note) to have something for the new gate to hold.
phase_update_healthgate_leg() {
    info "leg 5 — a container whose OWN healthcheck fails must hold the gate (#2383, manual battery M9)"
    if [ "${LEG4_PITHEAD_BOOT_PROVED:-0}" != "1" ]; then
        it_skip_leg "unhealthy-container gate refusal (#2383)" \
            "leg 4 did not reach a committed, provisioned guest on this run, so there is no live pithead-boot to install a fault bundle against" missing
        return
    fi
    local fbundle fbrc marker fmarker fdeadline
    info "building v3fault bundle (dashboard healthcheck forced to 'exit 1')"
    export PITHEAD_TEST_BREAK_HEALTHCHECK=1
    fbundle=$(_build_bundle v3fault)
    fbrc=$?
    unset PITHEAD_TEST_BREAK_HEALTHCHECK
    if [ "$fbrc" -ne 0 ] || [ -z "$fbundle" ]; then
        bundle_build_evidence
        bad "leg 5: the healthcheck-fault bundle build failed — read the build output above (/tmp/os-fault-bundle.log)"
        return
    fi
    ok "leg 5: built the fault bundle: $(basename "$fbundle")"
    _stage_bundle "$fbundle" && _install_or_fail "leg 5" && ok "leg 5: fault bundle installed into the spare slot" || {
        bad "leg 5: could not stage or install the fault bundle"
        return
    }
    # No mark-good here, deliberately: a plain reboot into the freshly installed slot, the same
    # shape an automatic A/B boot takes with nobody watching. pithead-boot's own gate decides this.
    _reboot_wait reboot 300 || {
        bad "leg 5: guest never returned after booting the fault slot"
        return
    }
    marker=$(SSH_TIMEOUT=20 _ssh cat /etc/pithead-test-marker 2>/dev/null)
    [ "$marker" = "v3fault" ] && ok "leg 5: the fault slot booted (v3fault)" || {
        bad "leg 5: expected v3fault booted after install, got '${marker:-none}'"
        return
    }
    # The gate loops up to 90x10s before rebooting itself once (#1065) — bound generously for that
    # plus image loading and stack start on the fallback slot.
    fdeadline=$(($(date +%s) + 1800))
    fmarker=""
    while [ "$(date +%s)" -lt "$fdeadline" ]; do
        fmarker=$(SSH_TIMEOUT=20 _ssh cat /etc/pithead-test-marker 2>/dev/null)
        [ "$fmarker" = "v2" ] && break
        sleep 15
    done
    if [ "$fmarker" = "v2" ]; then
        ok "leg 5: FALLBACK — the unhealthy dashboard held the gate and the guest fell back to v2"
    else
        bad "leg 5: expected the guest back on v2 after the fault boot's gate refusal, got '${fmarker:-none}' (30 min bound)"
    fi
    if _ssh "journalctl -u pithead-boot -b -1 2>/dev/null | grep -q 'container dashboard'"; then
        ok "leg 5: the fault boot's journal names the dashboard container that held the gate"
    else
        bad "leg 5: no 'container dashboard' line in the fault boot's journal — the gate did not name the cause"
    fi
}
