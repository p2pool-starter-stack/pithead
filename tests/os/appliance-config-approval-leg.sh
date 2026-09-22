#!/usr/bin/env bash
# Host-mediated configuration approval (#1959/#1966). Sourced by tests/os/run.sh; --self-test
# covers the pure approval verdicts without a guest or network.
# shellcheck source=tests/os/appliance-approval-verdict.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/appliance-approval-verdict.sh"

APPROVAL_RESTORE_SNAPSHOT=""
# Sensitive commits use the authenticated dashboard route. This phase repoints the appliance at
# reserved nodes and must restore the original config afterward.

# Keep this above the dashboard's 30-second answer window so a 202 response still carries the id.
dashboard_control_post() { # <route> <json-body>; keeps secrets out of curl's argv
    printf '%s' "$2" | dashboard_curl -sSk -m 45 -H 'Content-Type: application/json' \
        -H 'X-Pithead-Control: 1' --data-binary @- -w '\n%{http_code}' \
        "https://$ip/api/control/$1" 2>/dev/null
}
dashboard_config_body() { printf '%s' "$1" | jq -c '{config:.}'; }

approval_commit() { # <preview-id>; the confirmation envelope a sensitive commit now carries
    local id="$1"
    dashboard_control_request commit "$(jq -nc --arg id "$id" '{id:$id,confirm:"APPLY",approve:true,payout_suffixes:{}}')" 420
}

sensitive_preview() { # <config-body>; sets APPROVAL_PREVIEW / APPROVAL_REQUEST_ID
    local body="$1" deadline status
    APPROVAL_PREVIEW=$(dashboard_control_request preview "$body") || return 1
    APPROVAL_REQUEST_ID=$(printf '%s' "$APPROVAL_PREVIEW" | jq -r '.id // ""')
    [ -n "$APPROVAL_REQUEST_ID" ] || return 1
    deadline=$(($(date +%s) + 240))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        status=$(printf '%s' "$APPROVAL_PREVIEW" | jq -r '.status // "pending"' 2>/dev/null) || status=pending
        [ "$status" = pending ] || [ "$status" = running ] || return 0
        sleep 3
        APPROVAL_PREVIEW=$(dashboard_curl -sSk -m 8 "https://$ip/api/control/result?id=$APPROVAL_REQUEST_ID" 2>/dev/null)
    done
    return 1
}

approval_capture_restore_snapshot() {
    _ssh 'set -eu
test ! -e /data/pithead/data/control/.os1966-original-config.json
install -m 600 /data/pithead/config.json /data/pithead/data/control/.os1966-original-config.json
test "$(stat -c %a /data/pithead/data/control/.os1966-original-config.json)" = 600' || return 1
    APPROVAL_RESTORE_SNAPSHOT=/data/pithead/data/control/.os1966-original-config.json
}

approval_restore_pending() {
    [ -n "$APPROVAL_RESTORE_SNAPSHOT" ] || return 0
    # The apply restarts the control runner (#2363); over a request in flight it loses its result (#2094).
    _control_requests_drained || return 1
    _ssh 'set -euo pipefail
install -m 600 /data/pithead/data/control/.os1966-original-config.json /data/pithead/config.json
cd /data/pithead
./pithead apply -y >/dev/null
cmp -s /data/pithead/config.json /data/pithead/data/control/.os1966-original-config.json
rm -f /data/pithead/data/control/.os1966-original-config.json' || return 1
    APPROVAL_RESTORE_SNAPSHOT=""
}

approval_fixture_cleanup() {
    approval_restore_pending || {
        printf '  approval cleanup FAILED to restore the original node configuration\n' >&2
        return 1
    }
}

# The leg ahead of this one recreates the dashboard container, so a single curl the instant it
# returns is a race, not a measurement (#2059's contract, applied here after the #1929 leg was bitten
# by the same shape). Bounded retry, and the CALLER decides what an exhausted read means.
sensitive_live_config() { # prints the live config, or nothing
    local tries=0 out
    while [ "$tries" -lt 20 ]; do
        out=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null) && [ -n "$out" ] && {
            printf '%s' "$out"
            return 0
        }
        tries=$((tries + 1))
        sleep 3
    done
    return 1
}

phase_provision_sensitive_regressions() { # <dashboard-user> <dashboard-password>
    local DASH_USER="$1" DASH_PASS="$2" live proposed preview result rid before after audit

    # Attribute an unreadable dashboard to the earlier leg that left this precondition false.
    live=$(sensitive_live_config) || {
        bad "sensitive config NOT exercised: the dashboard never served /api/config (20 tries over ~60s) — an earlier leg left it unreadable; this is not a verdict on the sensitive-commit path"
        return
    }
    before=$(hostname_runtime_snapshot fixture-box)
    proposed=$(printf '%s' "$live" | jq -c '.dashboard.host = "fixture-next"')
    sensitive_preview "$(dashboard_config_body "$proposed")" || return
    preview=$APPROVAL_PREVIEW rid=$APPROVAL_REQUEST_ID
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id,confirm:"APPLY"}')")
    after=$(hostname_runtime_snapshot fixture-box)
    if printf '%s' "$result" | jq -e '.status == "rejected" and (.error | contains("typed payout confirmations"))' >/dev/null && [ "$before" = "$after" ]; then
        ok "day-two hostname commit is refused without the confirmation envelope and leaves identity unchanged"
    else
        bad "day-two hostname crossed the confirmation gate or changed during refusal"
        return
    fi

    sensitive_preview "$(dashboard_config_body "$proposed")" || {
        bad "could not preview the day-two hostname change"
        return
    }
    preview=$APPROVAL_PREVIEW rid=$APPROVAL_REQUEST_ID
    result=$(approval_commit "$rid")
    audit=$(_ssh "tail -n 20 /data/pithead/data/control/audit/control.log" 2>/dev/null)
    # Probe identity directly: subshell capture loses the harness failure tally.
    local identity_landed=unknown
    if [ -z "$result" ]; then
        if assert_appliance_hostname_identity fixture-next "confirmed day-two hostname" "$DASH_USER" "$DASH_PASS"; then
            identity_landed=landed
        fi
    fi
    # The audit must name THIS request and record the signed-in dashboard actor. It must NOT carry
    # an approver: that field had exactly one writer, the removed Telegram verifier (#2076).
    if { printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null || [ "$identity_landed" = landed ]; } &&
        printf '%s\n' "$audit" | jq -se --arg id "$rid" 'any(.[]; .id == $id and .status == "applied" and (.approver // "") == "")' >/dev/null &&
        { [ "$identity_landed" = landed ] || assert_appliance_hostname_identity fixture-next "confirmed day-two hostname" "$DASH_USER" "$DASH_PASS"; }; then
        ok "a confirmed day-two hostname commit applies, audits without an approver, and converges live identity"
    else
        bad "confirmed hostname commit did not bind apply, a clean audit row and live identity ($(approval_bind_payload "$result" "$audit" "$rid" "$identity_landed"))"
        return
    fi

    live=$(sensitive_live_config) || return
    proposed=$(printf '%s' "$live" | jq -c '.dashboard.auth.password = "os1966-physical-only"')
    sensitive_preview "$(dashboard_config_body "$proposed")" || return
    preview=$APPROVAL_PREVIEW rid=$APPROVAL_REQUEST_ID
    result=$(approval_commit "$rid")
    if ! physical_presence_password_refusal_verdict "$result"; then
        bad "host approval did not refuse the physical-presence-only dashboard-password edit ($(printf '%s' "$result" | jq -c '{status,error}' 2>/dev/null || printf 'unreadable result'))"
        return
    fi
    if ! sensitive_live_config >/dev/null; then
        bad "physical-presence refusal left the authenticated dashboard login unreadable after 20 retries"
        return
    fi
    ok "host approval cannot cross the physical-presence-only dashboard-password boundary"

    phase_provision_remote_node_regressions
}

_hostname_landed_fallback_self_test() (
    local output
    sensitive_live_config() { printf '{"dashboard":{"host":"fixture-box"}}'; }
    hostname_runtime_snapshot() { printf 'unchanged'; }
    sensitive_preview() {
        APPROVAL_PREVIEW='{"id":"r1","status":"previewed"}'
        APPROVAL_REQUEST_ID=r1
    }
    dashboard_control_request() { printf '{"status":"rejected","error":"typed payout confirmations"}'; }
    approval_commit() { printf ''; }
    _ssh() { printf '%s\n' '{"id":"r1","status":"applied","approver":""}'; }
    assert_appliance_hostname_identity() { return 0; }
    ok() { printf 'ok: %s\n' "$1"; }
    bad() {
        printf 'bad: %s\n' "$1"
        return 1
    }
    output=$(phase_provision_sensitive_regressions fixture-user fixture-password 2>&1) || true
    case "$output" in
    *'ok: a confirmed day-two hostname commit applies, audits without an approver, and converges live identity'*) ;;
    *) return 1 ;;
    esac
)

# #2094's root fix at the caller: the restore's own `pithead apply` restarts the control runner
# (#2363), so a spool that never drains must stop it BEFORE the apply reaches the guest, not after.
# Driving the real function with one request stuck in requests/ forever must refuse, and must leave
# `pithead apply` uncalled — removing the `_control_requests_drained` line makes both halves fail.
# The real `_control_requests_drained` is driven by selftest-run-modules.sh; deleting this caller's
# call to it fails both halves below.
_restore_waits_for_control_drain_self_test() (
    local applied=0 drained=1
    APPROVAL_RESTORE_SNAPSHOT=/data/pithead/data/control/.os1966-original-config.json
    _control_requests_drained() { [ "$drained" -eq 0 ]; }
    _ssh() { case "$*" in *'pithead apply'*) applied=1 ;; esac }
    ! approval_restore_pending || return 1
    [ "$applied" -eq 0 ] || return 1
    drained=0
    approval_restore_pending || return 1
    [ "$applied" -eq 1 ]
)

_approval_self_test() {
    local f=0 here
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    _control_request_transport_self_test || f=$((f + 1))
    # Called from HERE, not from _approval_bind_payload_self_test: that one is also driven
    # standalone by tests/os/selftest-row-payloads.sh, which sources this verdict file WITHOUT
    # provision-browser-submit.sh — so `dashboard_control_request` does not exist there and the
    # check dies as a missing command rather than a verdict.
    _control_request_lost_response_self_test || f=$((f + 1))
    _approval_bind_payload_self_test >/dev/null || f=$((f + 1))
    _hostname_landed_fallback_self_test || f=$((f + 1))
    _restore_waits_for_control_drain_self_test || f=$((f + 1))
    grep -Fq '_control_requests_drained || {' "$here/appliance-dashboard-exposure-leg.sh" || f=$((f + 1))
    _physical_presence_password_refusal_self_test || f=$((f + 1))
    _reserved_node_preview_payload_self_test >/dev/null || f=$((f + 1))
    grep -Fq 'phase_provision_sensitive_regressions "$pv_user" "$pv_pass" || bad' "$here/phases/provision-initial.sh" || f=$((f + 1))
    [ "$f" -eq 0 ] || {
        printf 'appliance-config-approval-leg self-test FAILED: %s checks\n' "$f"
        return 1
    }
    printf 'appliance-config-approval-leg self-test passed\n'
}
# shellcheck source=tests/os/appliance-node-runtime-leg.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/appliance-node-runtime-leg.sh"
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --self-test ]; then
    set -uo pipefail
    # shellcheck source=tests/os/provision-browser-submit.sh
    . "$(cd "$(dirname "$0")" && pwd)/provision-browser-submit.sh"
    # shellcheck source=tests/integration/lib/mergemine-probe.sh
    . "$(cd "$(dirname "$0")/../integration/lib" && pwd)/mergemine-probe.sh"
    _approval_self_test && _remote_node_self_test
fi
