# shellcheck shell=bash
#
# Deterministic reproduction of #2219 (sourced by tests/os/run.sh; drives its own --self-test).
#
# Job 186 hit the control-runner reboot-wedge by accident: DEPLOYMENT_COMPLETED read false for one
# request already queued during a legitimate transient window, and — pre-fix — a failed
# control-run-pending never got another try (systemd's default start-limit tripped and nothing ever
# reset it short of a reboot). That race is timing-dependent: re-running the same battery (job 223)
# never landed on it at all. This leg forces the identical shape on purpose — flip
# DEPLOYMENT_COMPLETED false under the live guest, queue one preview request against it, flip it
# back — so the retry-and-recover behaviour has tier-4 coverage that does not depend on catching the
# real race in flight.
#
# Verified against the GUEST's own `systemctl show -p NRestarts`, not only the HTTP result: a
# request that eventually completes could otherwise be explained by something other than the unit
# actually retrying (a stale poll, an unrelated second trigger). NRestarts only climbs on an
# systemd-scheduled Restart=, which is exactly the mechanism #2219 added.
GUEST_ENV=/data/pithead/.env
_control_recovery_nrestarts() { _ssh "systemctl show -p NRestarts --value pithead-control.service" 2>/dev/null | tr -d '\r\n'; }
_control_recovery_status() { dashboard_curl -sSk -m 8 "https://$ip/api/control/result?id=$1" 2>/dev/null | jq -r '.status // "pending"' 2>/dev/null; }
# Best-effort clear of the fault THIS leg injected. Never swallowed with `|| true`: a restore that
# silently fails leaves the guest deliberately faulted (DEPLOYMENT_COMPLETED=false) for every phase
# that runs after this one, and a swallowed failure gives no signal that THIS leg is why they broke.
_control_recovery_restore() {
    _ssh "sed -i 's/^DEPLOYMENT_COMPLETED=false/DEPLOYMENT_COMPLETED=true/' '$GUEST_ENV'" && return 0
    bad "control-runner recovery: could not clear the injected fault — the guest is left with DEPLOYMENT_COMPLETED=false; every phase after this one is now suspect"
    return 1
}
phase_provision_control_recovery() { # <ip> <dashboard-user> <dashboard-password>
    # shellcheck disable=SC2034 # DASH_USER/DASH_PASS: read by dashboard_curl (sibling file) via dynamic scope
    local ip="$1" DASH_USER="$2" DASH_PASS="$3" cfg rid restarts0 restarts1 status deadline pretries=0
    # A sibling leg's own control request can still be settling on the guest (the runner drains its
    # spool on its own schedule) — a single point-in-time read here would blame THIS leg for a
    # precondition a slow-to-settle predecessor left transiently false. Give it up to 30s to
    # converge before calling the leg unable to run (#2374): this is the same fault this leg
    # reproduces on purpose, just arriving from outside instead of from `sed -i` below.
    while ! _ssh "grep -qx 'DEPLOYMENT_COMPLETED=true' '$GUEST_ENV'"; do
        pretries=$((pretries + 1))
        [ "$pretries" -lt 10 ] || {
            bad "control-runner recovery: guest .env is not DEPLOYMENT_COMPLETED=true before the fault — leg cannot run"
            return
        }
        sleep 3
    done
    # Name the wait when it engaged: a run whose poll absorbed a settling predecessor must be
    # distinguishable from one where the precondition was true on the first read (#2374).
    [ "$pretries" -eq 0 ] || info "control-runner recovery: guest .env settled to DEPLOYMENT_COMPLETED=true after $((pretries * 3))s ($pretries retries)"
    restarts0=$(_control_recovery_nrestarts)
    _ssh "sed -i 's/^DEPLOYMENT_COMPLETED=true/DEPLOYMENT_COMPLETED=false/' '$GUEST_ENV'" || {
        bad "control-runner recovery: could not fault DEPLOYMENT_COMPLETED"
        return
    }
    cfg=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null | jq -c '.dashboard.energy.cost_per_kwh = 0.21')
    rid=$(dashboard_control_post preview "$(dashboard_config_body "$cfg")" | jq -r '.id // ""' 2>/dev/null)
    if [ -z "$rid" ]; then
        _control_recovery_restore
        bad "control-runner recovery: the faulted preview never queued (no id)"
        return
    fi
    if [ "$(_control_recovery_status "$rid")" = "previewed" ]; then
        _control_recovery_restore
        bad "control-runner recovery: the preview resolved while DEPLOYMENT_COMPLETED was false — the fault never took"
        return
    fi
    deadline=$(($(date +%s) + 20))
    restarts1="$restarts0"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        restarts1=$(_control_recovery_nrestarts)
        [ "${restarts1:-0}" -gt "${restarts0:-0}" ] 2>/dev/null && break
        sleep 3
    done
    if ! [ "${restarts1:-0}" -gt "${restarts0:-0}" ] 2>/dev/null; then
        _control_recovery_restore
        bad "control-runner recovery: the runner never retried the faulted request (NRestarts stayed at ${restarts0:-0}) — the #2219 fix did not engage"
        return
    fi
    ok "control-runner retries a transient setup-fault rejection on its own (NRestarts ${restarts0:-0} -> $restarts1)"
    _control_recovery_restore || return
    deadline=$(($(date +%s) + 45))
    status=pending
    while [ "$(date +%s)" -lt "$deadline" ]; do
        status=$(_control_recovery_status "$rid")
        [ "$status" = "previewed" ] && break
        sleep 3
    done
    if [ "$status" = "previewed" ]; then
        ok "the request queued during the fault is processed once it clears — no reboot required (#2219)"
    else
        bad "control-runner recovery: the already-queued request never completed after the fault cleared (status=$status)"
    fi
}

# --- self-test ---------------------------------------------------------------------------------
#
# No guest: every guest read/write is a stub, driven through the real function so a control that
# never retries or never converges is what turns red, not a description of one.
_control_recovery_self_test() {
    local f=0 PASS=0 FAIL=0 env_state restarts
    sleep() { :; }                           # the entry precondition and the recovery poll both retry on a real clock (#2374)
    dashboard_config_body() { printf '{}'; } # stubbed dashboard_control_post below ignores its input

    # Guard: an .env that is not DEPLOYMENT_COMPLETED=true to start must refuse to run the leg
    # rather than fault a box that was never healthy.
    _ssh() {
        [ "$1" = "grep -qx 'DEPLOYMENT_COMPLETED=true' '$GUEST_ENV'" ] && return 1
        return 0
    }
    dashboard_curl() { echo '{}'; }
    dashboard_control_post() { echo '{"id":"x"}'; }
    PASS=0 FAIL=0
    phase_provision_control_recovery 1.2.3.4 u p >/dev/null
    [ "$FAIL" -eq 1 ] && [ "$PASS" -eq 0 ] || {
        printf 'a non-deployed guest was not refused\n' >&2
        f=$((f + 1))
    }
    unset -f _ssh dashboard_curl dashboard_control_post

    # A guest that is still settling a sibling leg's own request reads DEPLOYMENT_COMPLETED=false
    # for a few polls, then true: the leg must wait it out rather than blame itself for a
    # precondition that was never really broken (#2374).
    local precheck_calls=0
    env_state=true restarts=0
    _ssh() {
        case "$1" in
        "grep -qx 'DEPLOYMENT_COMPLETED=true' '$GUEST_ENV'")
            precheck_calls=$((precheck_calls + 1))
            [ "$precheck_calls" -ge 3 ]
            ;;
        "sed -i 's/^DEPLOYMENT_COMPLETED=true/DEPLOYMENT_COMPLETED=false/' '$GUEST_ENV'") env_state=false ;;
        "sed -i 's/^DEPLOYMENT_COMPLETED=false/DEPLOYMENT_COMPLETED=true/' '$GUEST_ENV'") env_state=true ;;
        "systemctl show -p NRestarts --value pithead-control.service")
            [ "$env_state" = false ] && restarts=1
            echo "$restarts"
            ;;
        esac
    }
    dashboard_curl() {
        [ "$env_state" = true ] && echo '{"status":"previewed"}' || echo '{"status":"pending"}'
    }
    dashboard_control_post() { echo '{"id":"settles"}'; }
    PASS=0 FAIL=0
    local settled_out # a file, not $(...): a subshell would lose this run's PASS/FAIL counts
    settled_out=$(mktemp)
    phase_provision_control_recovery 1.2.3.4 u p >"$settled_out"
    [ "$FAIL" -eq 0 ] && [ "$PASS" -eq 2 ] || {
        printf 'a precondition that settles within the retry window was not given the chance to (pass=%s fail=%s)\n' "$PASS" "$FAIL" >&2
        f=$((f + 1))
    }
    # An engaged poll must say so: a green run that waited and a green run that never had to are
    # otherwise indistinguishable in the transcript (#2374).
    grep -q 'settled to DEPLOYMENT_COMPLETED=true after 6s (2 retries)' "$settled_out" || {
        printf 'an engaged precondition poll did not report how long it waited\n' >&2
        f=$((f + 1))
    }
    rm -f "$settled_out"
    unset -f _ssh dashboard_curl dashboard_control_post

    # A runner that never retries (NRestarts stays put) must turn red naming the fix as unengaged,
    # not silently time out.
    env_state=true
    _ssh() {
        case "$1" in
        "grep -qx 'DEPLOYMENT_COMPLETED=true' '$GUEST_ENV'") [ "$env_state" = true ] ;;
        "sed -i 's/^DEPLOYMENT_COMPLETED=true/DEPLOYMENT_COMPLETED=false/' '$GUEST_ENV'") env_state=false ;;
        "sed -i 's/^DEPLOYMENT_COMPLETED=false/DEPLOYMENT_COMPLETED=true/' '$GUEST_ENV'") env_state=true ;;
        "systemctl show -p NRestarts --value pithead-control.service") echo 0 ;;
        esac
    }
    dashboard_curl() { echo '{"status":"pending"}'; }
    dashboard_control_post() { echo '{"id":"stuck"}'; }
    PASS=0 FAIL=0
    phase_provision_control_recovery 1.2.3.4 u p >/dev/null
    [ "$FAIL" -eq 1 ] && [ "$PASS" -eq 0 ] || {
        printf 'a runner that never retries was not caught (pass=%s fail=%s)\n' "$PASS" "$FAIL" >&2
        f=$((f + 1))
    }
    unset -f _ssh dashboard_curl dashboard_control_post

    # The recovered path: NRestarts climbs once faulted, and the queued request resolves once the
    # fault clears — both oks, no reds.
    env_state=true restarts=0
    _ssh() {
        case "$1" in
        "grep -qx 'DEPLOYMENT_COMPLETED=true' '$GUEST_ENV'") [ "$env_state" = true ] ;;
        "sed -i 's/^DEPLOYMENT_COMPLETED=true/DEPLOYMENT_COMPLETED=false/' '$GUEST_ENV'") env_state=false ;;
        "sed -i 's/^DEPLOYMENT_COMPLETED=false/DEPLOYMENT_COMPLETED=true/' '$GUEST_ENV'") env_state=true ;;
        "systemctl show -p NRestarts --value pithead-control.service")
            [ "$env_state" = false ] && restarts=1
            echo "$restarts"
            ;;
        esac
    }
    # A real box takes a few poll cycles to converge once the fault clears; this stub only needs
    # to prove the loop DOES converge once env_state flips back, not model the exact cadence — the
    # NRestarts assertion above is what proves the retry itself, this one proves the request that
    # was stuck is the same one that lands.
    dashboard_curl() {
        [ "$env_state" = true ] && echo '{"status":"previewed"}' || echo '{"status":"pending"}'
    }
    dashboard_control_post() { echo '{"id":"recovers"}'; }
    PASS=0 FAIL=0
    phase_provision_control_recovery 1.2.3.4 u p >/dev/null
    [ "$FAIL" -eq 0 ] && [ "$PASS" -eq 2 ] || {
        printf 'the recovered path did not report both oks cleanly (pass=%s fail=%s)\n' "$PASS" "$FAIL" >&2
        f=$((f + 1))
    }
    unset -f _ssh dashboard_curl dashboard_control_post

    # A restore that itself fails (the guest is left DEPLOYMENT_COMPLETED=false) must be its own
    # visible bad, not a swallowed `|| true` — otherwise every phase after this one fails for an
    # unrelated reason with no signal that this leg's cleanup is why.
    env_state=true
    _ssh() {
        case "$1" in
        "grep -qx 'DEPLOYMENT_COMPLETED=true' '$GUEST_ENV'") [ "$env_state" = true ] ;;
        "sed -i 's/^DEPLOYMENT_COMPLETED=true/DEPLOYMENT_COMPLETED=false/' '$GUEST_ENV'") env_state=false ;;
        "sed -i 's/^DEPLOYMENT_COMPLETED=false/DEPLOYMENT_COMPLETED=true/' '$GUEST_ENV'") return 1 ;; # restore itself is broken
        "systemctl show -p NRestarts --value pithead-control.service") echo 0 ;;
        esac
    }
    dashboard_curl() { echo '{"status":"pending"}'; }
    dashboard_control_post() { echo '{"id":"stuck"}'; }
    PASS=0 FAIL=0
    local out_file
    out_file=$(mktemp)
    phase_provision_control_recovery 1.2.3.4 u p >"$out_file"
    if [ "$FAIL" -eq 2 ] && [ "$PASS" -eq 0 ] && grep -q "could not clear the injected fault" "$out_file"; then
        :
    else
        printf 'a failed restore was not reported on its own (pass=%s fail=%s out=%s)\n' "$PASS" "$FAIL" "$(cat "$out_file")" >&2
        f=$((f + 1))
    fi
    rm -f "$out_file"
    unset -f _ssh dashboard_curl dashboard_control_post

    if [ "$f" -ne 0 ]; then
        printf 'control-runner-recovery-leg self-test FAILED: %s checks\n' "$f"
        return 1
    fi
    printf 'control-runner-recovery-leg self-test passed\n'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = --self-test ]; then
    ok() {
        PASS=$((PASS + 1))
        printf '  ok %s\n' "$1"
    }
    bad() {
        FAIL=$((FAIL + 1))
        printf '  bad %s\n' "$1"
    }
    info() { printf '  info %s\n' "$1"; } # real runs get it from tests/os/lib/core.sh
    _control_recovery_self_test
fi
