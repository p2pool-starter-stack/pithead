# shellcheck shell=bash
#
# The post-validation setup-failure leg for phase_provision (#1955/#1966). Sourced by
# tests/os/run.sh; driven at tier 1 through provision-browser-submit.sh's `--self-test`, which
# sources this file the same way it already sources the approval leg.
#
# A sibling rather than more lines in provision-browser-submit.sh, which sat exactly on the
# 400-line target: that file's subject is what a browser SENDS, this one's is what the machine
# does when provisioning fails after the answers were accepted. Both are read by the same phase.
# `failed`, not `setup`. The two are a real distinction the wizard makes and this verdict had it
# backwards: a preflight refusal keeps the operator ON the form (`setup`, which
# node_preflight_state_retained asserts and which passes), while a setup that failed after the
# answers were accepted reopens the page as `failed`. The dashboard pins that vocabulary in its own
# tier 1 (`dashboard/tests/web/test_wizard_recovery.py` asserts `stage == "failed"` twice, and
# `wizard_recovery.py` branches on it), so this was checkable without a guest all along.
#
# It survived because the fixture below was written from THIS function's assumption instead of
# from a real page — it asserted that `failed` must be REJECTED — so the control was green by
# construction and pinned the wrong word. The row was also unreachable until the fault was armed
# where it could actually reach setup (#2050), so nothing else contradicted it. Measured on a kept
# guest 2026-09-11: stage `failed`, the error text, the submitted wallet and tari.mode `local`.
setup_failure_state_retained() { # <wizard-state-json> <expected-wallet>
    printf '%s' "$1" | jq -e --arg m "$2" '
        .stage == "failed" and (.error | type == "string" and length > 0) and
        .config.monero.wallet_address == $m and .config.tari.mode == "local"' >/dev/null
}
# THE ARMING, and why it is a stub rather than an absence (#2050). All three of the wizard's
# validations reach caddy_hash_password_b64, which greps the pinned caddy ref straight out of
# docker-compose.yml. Removing the file therefore faults parse_and_validate_config — which has its
# own recovery (the page reopens carrying the validator's message) and never calls setup at all.
# The bench measured exactly that and read it as a hang: the harness sat out its 24x5s poll for a
# credentials handoff that the validator path correctly never publishes, while the machine was
# sitting on a reopened form. So the stub keeps the caddy line verbatim and makes everything after
# it unparseable: validation passes unchanged, the handoff is published, and the first
# `docker compose` that must actually READ the file — the `up` inside setup's stack_up, well past
# the render_env that writes DEPLOYMENT_COMPLETED — refuses. That is a post-validation setup
# failure, which is what this leg is named for.
SETUP_FAULT_MARK=PITHEAD_OS_2050_STUB
restore_setup_fault() { _ssh "mv -f /run/pithead-os-1966-docker-compose.yml /data/pithead/docker-compose.yml &&
    test -s /data/pithead/docker-compose.yml && test ! -e /run/pithead-os-1966-docker-compose.yml &&
    ! grep -q $SETUP_FAULT_MARK /data/pithead/docker-compose.yml"; }
provision_setup_failure_recovery() { # <ip> <authenticated-cookie-jar> <old-token>
    local ip="$1" jar="$2" old_token="$3" handoff="" state code new_token="" tries=0
    local live=/data/pithead/docker-compose.yml backup=/run/pithead-os-1966-docker-compose.yml
    if _ssh "test -s '$live' && test ! -e '$backup' && mv '$live' '$backup' && test -s '$backup' && { echo '# $SETUP_FAULT_MARK'; grep -oE 'caddy:[0-9.]+@sha256:[a-f0-9]+' '$backup' | head -1 | sed 's/^/# /'; echo 'services: [ not a compose file'; } >'$live' && grep -q '$SETUP_FAULT_MARK' '$live' && grep -qE 'caddy:[0-9.]+@sha256:[a-f0-9]+' '$live'"; then
        ok "post-validation setup fault is armed: the Compose file still validates and cannot be started"
    else
        # The arm moves the real file BEFORE it writes and checks the stub, so a failure after
        # that mv would leave the guest with no usable Compose file and nothing to put it back.
        # Restore only over an absent file or our OWN stub — never over a file we did not replace,
        # which is what a stale backup from an earlier run would otherwise be written onto.
        _ssh "test -e '$backup' && { test ! -s '$live' || grep -q $SETUP_FAULT_MARK '$live'; } && mv -f '$backup' '$live'" || true
        bad "could not arm the disposable post-validation setup fault"
        return 1
    fi
    code=$(provision_browser_submit "$ip" "$jar")
    if [ "$code" = "200" ]; then
        ok "the valid setup is accepted before the host-side fault fires"
    else
        restore_setup_fault || bad "post-validation fault cleanup failed after submit refusal"
        bad "faulted setup was not accepted for host processing (HTTP ${code:-none})"
        return 1
    fi
    while [ "$tries" -lt 24 ]; do
        handoff=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        printf '%s' "$handoff" | jq -e '.password' >/dev/null 2>&1 && break
        sleep 5
        tries=$((tries + 1))
    done
    if [ "$tries" -ge 24 ]; then
        restore_setup_fault || bad "post-validation fault cleanup failed after handoff timeout"
        bad "faulted setup never reached its credentials handoff"
        stack_never_up_evidence # #2043: the guest is recycled next, so ask it now
        return 1
    fi
    if ! curl -fsSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null; then
        restore_setup_fault || bad "post-validation fault cleanup failed after handoff refusal"
        bad "faulted setup credentials could not be acknowledged"
        return 1
    fi
    if ! _ssh "for i in \$(seq 60); do test -s /data/pithead/data/firstboot/error.txt && test -s '$backup' && grep -q '$SETUP_FAULT_MARK' '$live' && exit 0; sleep 5; done; exit 1"; then
        restore_setup_fault || bad "post-validation fault cleanup failed after setup timeout"
        bad "the armed host setup fault never returned a recorded failure"
        return 1
    fi
    if restore_setup_fault; then
        ok "post-validation setup fault cleanup restores the exact Compose file"
    else
        bad "post-validation setup fault cleanup did not restore the Compose file"
        return 1
    fi
    tries=0
    while [ "$tries" -lt 40 ]; do
        new_token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$new_token" ] && [ "$new_token" != "$old_token" ] && break
        sleep 3
        tries=$((tries + 1))
    done
    [ "$tries" -lt 40 ] && _wait_setup_page 120 || {
        bad "failed setup did not reopen the token-gated page"
        return 1
    }
    : >"$jar"
    curl -fsSk -c "$jar" -d "token=$new_token" "https://$ip/auth" -o /dev/null 2>/dev/null || {
        bad "failed setup's fresh token was not accepted"
        return 1
    }
    state=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/wizard-state" 2>/dev/null)
    if grep -q "wizard_session" "$jar" && setup_failure_state_retained "$state" "$HARNESS_WALLET"; then
        ok "host setup failure reopens with a useful error and the safe values retained"
    else
        # The red carried no payload, and reading the page off a kept guest is what finally said
        # which clause was wrong (#2050: it was this verdict's, not the product's). Name the
        # fields the verdict reads so the next failure is diagnosable from the log alone.
        bad "host setup failure did not reopen a useful retained form (stage=$(printf '%s' "$state" | jq -rc '.stage // "none"' 2>/dev/null) error=$(printf '%s' "$state" | jq -rc '(.error // "") | .[0:60]' 2>/dev/null) wallet=$(printf '%s' "$state" | jq -rc '(.config.monero.wallet_address // "") | .[0:12]' 2>/dev/null) tari.mode=$(printf '%s' "$state" | jq -rc '.config.tari.mode // "none"' 2>/dev/null))"
        return 1
    fi
}

# --- self-test ---------------------------------------------------------------------------------
#
# The retention verdict, and one control per field it reads: a stage that is not `setup`, an empty
# error, and a wallet that is not the submitted one must each redden it on their own. Without the
# three negatives "it returned 0" would also be true of a verdict that tested nothing.
_setup_failure_self_test() {
    # The shape a real reopened page serves, read off a kept guest rather than re-derived from the
    # assertion: stage `failed`, the setup log's last [ERROR], and the submitted answers back.
    local failed='{"stage":"failed","error":"[ERROR] Timed out waiting for the P2Pool Tor hidden-service hostname.","config":{"monero":{"wallet_address":"wallet"},"tari":{"mode":"local"}}}'
    setup_failure_state_retained "$failed" wallet || return 1
    # `setup` is the PREFLIGHT refusal's stage — still on the form, nothing attempted. Accepting it
    # here would let a leg that never reached setup pass as if a setup had failed and recovered.
    ! setup_failure_state_retained "${failed/\"failed\"/\"setup\"}" wallet || return 1
    ! setup_failure_state_retained "${failed/\[ERROR\] Timed out waiting for the P2Pool Tor hidden-service hostname./}" wallet || return 1
    ! setup_failure_state_retained "${failed/\"wallet\"/\"lost\"}" wallet || return 1
    # tari.mode had no negative case: replacing the clause with `true` left this self-test green
    # (measured). `remote` is the near-miss that matters — it is what the preflight leg submits
    # earlier in this same phase, so a page that handed back THAT attempt instead of the accepted
    # one would otherwise pass.
    ! setup_failure_state_retained "${failed/\"local\"/\"remote\"}" wallet || return 1
    echo "setup-failure-recovery self-test: failed-page retention controls passed"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--self-test" ]; then
    set -uo pipefail # what tests/os/run.sh runs the helpers under
    _setup_failure_self_test
    exit $?
fi
