#!/usr/bin/env bash
# Host-mediated configuration approval (#1959/#1966). Sourced by tests/os/run.sh; --self-test
# covers the pure approval verdicts without a guest or network.
# shellcheck source=tests/os/appliance-approval-verdict.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/appliance-approval-verdict.sh"

# shellcheck source=tests/os/appliance-password-fixture.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/appliance-password-fixture.sh"

APPROVAL_RESTORE_SNAPSHOT=""
# Sensitive commits use the authenticated dashboard route. This phase repoints the appliance at
# reserved nodes and must restore the original config afterward.

# Keep this above the dashboard's 30-second answer window so a 202 response still carries the id.
dashboard_control_post() { # <route> <json-body> [timeout]; keeps secrets out of curl's argv
    local cap=45
    [ -z "${3:-}" ] || cap="$3"
    printf '%s' "$2" | dashboard_curl -sSk -m "$cap" -H 'Content-Type: application/json' \
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
    # Keep the harness restore at a quiet phase boundary; apply does not stop a running runner (#2363).
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

# The served module proves the dashboard image carries #3239, without a browser.
config_version_asset_verdict() { # <module body>; an empty or unrelated response cannot pass
    [ -n "$1" ] &&
        grep -Fq 'Saving is blocked' <<<"$1" &&
        grep -Fq '_config_version_newer' <<<"$1" &&
        ! grep -Fq 'Config file version' <<<"$1"
}

assert_shipped_config_version_asset() {
    local tries=0 body="" readable=0
    while [ "$tries" -lt 20 ]; do
        if body=$(dashboard_curl -fsSk -m 8 "https://$ip/static/config/configversion.mjs" 2>/dev/null) && [ -n "$body" ]; then
            readable=1
            break
        fi
        tries=$((tries + 1))
        sleep 3
    done
    if [ "$readable" -ne 1 ]; then
        bad "shipped config-version asset (#3239) NOT exercised: module unreadable or empty after 20 tries"
        return 1
    fi
    if config_version_asset_verdict "$body"; then
        ok "shipped config-version asset hides the stamp and retains the newer-config warning (#3239)"
    else
        bad "shipped config-version asset (#3239): expected newer-config warning and flag without Config file version text"
        return 1
    fi
}

# Commit a dashboard-password change and read its verdict from the host's result spool: the
# dashboard's own result poll authenticates with the login this very commit replaces (#2367).
password_commit_via_host() { # <new-password>; uses DASH_USER/DASH_PASS (current login) by dynamic scope
    local live proposed rid result tries=0
    live=$(sensitive_live_config) || {
        bad "dashboard-password repoint NOT exercised: /api/config unreadable before the commit"
        return 1
    }
    proposed=$(printf '%s' "$live" | jq -c --arg p "$1" '.dashboard.auth.password = $p')
    sensitive_preview "$(dashboard_config_body "$proposed")" || {
        bad "dashboard-password repoint NOT exercised: the preview never returned"
        return 1
    }
    # The owner's #2367 ruling: the operator sees the cost before confirming. Refuse to commit
    # unless the host preview is envelope-gated and names the lockout and console-login costs.
    if ! dashboard_password_preview_warns_verdict "$APPROVAL_PREVIEW"; then
        bad "dashboard-password preview did not warn before the commit (want previewed, approval_required, lockout + console-login text; got $(printf '%s' "$APPROVAL_PREVIEW" | jq -c '{status, approval_required, warns: ([.changes[]?.msg] | any(contains("locks this session out") and contains("console root login")))}' 2>/dev/null || printf 'unparseable preview'))"
        return 1
    fi
    rid=$APPROVAL_REQUEST_ID
    dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id,confirm:"APPLY",approve:true,payout_suffixes:{}}')" 20 >/dev/null || true
    while [ "$tries" -lt 140 ]; do
        result=$(_ssh "cat /data/pithead/data/control/results/$rid.json" 2>/dev/null) &&
            ! printf '%s' "$result" | jq -e '.status | IN("pending","accepted","running")' >/dev/null 2>&1 && break
        result="" tries=$((tries + 1))
        sleep 3
    done
    dashboard_password_repoint_applied_verdict "$result" && return 0
    bad "dashboard-password repoint did not commit behind typed APPLY ($(control_result_payload "$result"))"
    return 1
}

phase_provision_sensitive_regressions() { # <dashboard-user> <dashboard-password>
    local DASH_USER="$1" DASH_PASS="$2" live proposed preview result rid before after audit

    # Attribute an unreadable dashboard to the earlier leg that left this precondition false.
    live=$(sensitive_live_config) || {
        bad "sensitive config NOT exercised: the dashboard never served /api/config (20 tries over ~60s) — an earlier leg left it unreadable; this is not a verdict on the sensitive-commit path"
        return
    }
    assert_shipped_config_version_asset || return 1
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

    password_fixture_round_trip

}

_config_version_asset_self_test() (
    local newer='cfg?._config_version_newer ? "Saving is blocked" : null'
    local older='cfg?._config_version_newer ? "Saving is blocked" : `Config file version ${version}`'
    config_version_asset_verdict "$newer" || return 1
    local body
    for body in "$older" "" '   ' 'Saving is blocked' '_config_version_newer' \
        "$newer Config file version"; do
        ! config_version_asset_verdict "$body" || return 1
    done
    local mode=ready sleeps=0 passed=0 failed=0 ip=fixture-address
    dashboard_curl() {
        case "$*" in *'/static/config/configversion.mjs'*) ;; *) return 1 ;; esac
        case "$mode" in
        ready) printf '%s' "$newer" ;;
        old) printf '%s' "$older" ;;
        empty) return 0 ;;
        unreadable)
            printf '%s' "$newer"
            return 22
            ;;
        retry) [ "$sleeps" -gt 0 ] && printf '%s' "$newer" ;;
        esac
    }
    sleep() { sleeps=$((sleeps + 1)); }
    ok() { passed=$((passed + 1)); }
    bad() { failed=$((failed + 1)); }
    assert_shipped_config_version_asset && [ "$passed" = 1 ] && [ "$failed" = 0 ] || return 1
    mode=retry
    assert_shipped_config_version_asset && [ "$passed" = 2 ] && [ "$sleeps" = 1 ] || return 1
    for mode in old empty unreadable; do
        passed=0 failed=0 sleeps=0
        ! assert_shipped_config_version_asset || return 1
        [ "$passed" = 0 ] && [ "$failed" = 1 ] || return 1
        [ "$mode" = old ] || [ "$sleeps" = 20 ] || return 1
    done
)

_config_version_asset_phase_self_test() (
    local ip=fixture-address asset_module='cfg?._config_version_newer ? "Saving is blocked" : null'
    local previews=0 passed=0 failed=0
    sensitive_live_config() { printf '{"dashboard":{"host":"fixture-box"}}'; }
    dashboard_curl() { printf '%s' "$asset_module"; }
    hostname_runtime_snapshot() { printf unchanged; }
    sensitive_preview() {
        previews=$((previews + 1))
        return 1
    }
    ok() { passed=$((passed + 1)); }
    bad() { failed=$((failed + 1)); }
    phase_provision_sensitive_regressions fixture-user fixture-password || true
    [ "$passed" = 1 ] && [ "$failed" = 0 ] && [ "$previews" = 1 ] || return 1
    asset_module+=' Config file version'
    previews=0 passed=0 failed=0
    ! phase_provision_sensitive_regressions fixture-user fixture-password || return 1
    [ "$passed" = 0 ] && [ "$failed" = 1 ] && [ "$previews" = 0 ]
)

_password_commit_via_host_self_test() (
    local msg="Dashboard login password CHANGED — a mistyped password locks this session out, and on the appliance it is also the console root login."
    local good preview committed
    good=$(jq -nc --arg m "$msg" '{id:"r1",status:"previewed",approval_required:true,changes:[{msg:$m}]}')
    sensitive_live_config() { printf '{"dashboard":{"auth":{"password":"old"}}}'; }
    sensitive_preview() { APPROVAL_PREVIEW=$preview APPROVAL_REQUEST_ID=r1; }
    dashboard_control_request() {
        committed=1
        return 1
    }
    bad() { :; }
    _ssh() { printf '{"status":"applied"}'; }
    preview=$good committed=0
    password_commit_via_host new && [ "$committed" = 1 ] || exit 1
    # A preview missing the status, the approval flag or either warning is refused BEFORE commit.
    for bad_preview in "$(jq -c 'del(.status)' <<<"$good")" "$(jq -c '.approval_required=false' <<<"$good")" \
        "$(jq -c '.changes[0].msg|=sub("locks this session out";"")' <<<"$good")" \
        "$(jq -c '.changes[0].msg|=sub("console root login";"")' <<<"$good")"; do
        preview=$bad_preview committed=0
        ! password_commit_via_host new && [ "$committed" = 0 ] || exit 1
    done
    preview=$good committed=0
    _ssh() { printf '{"status":"rejected","error":"type APPLY"}'; }
    ! password_commit_via_host new || exit 1
)

_hostname_landed_fallback_self_test() (
    local output ip=fixture-address
    sensitive_live_config() { printf '{"dashboard":{"host":"fixture-box"}}'; }
    dashboard_curl() { printf 'cfg?._config_version_newer ? "Saving is blocked" : null'; }
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

# The restore keeps its own phase boundary quiet before `pithead apply` (#2363). Driving the real
# function with one request stuck in requests/ forever must refuse, and must leave `pithead apply`
# uncalled — removing the `_control_requests_drained` line makes both halves fail.
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

# #2333: a fresh-chain sync-gate-hold row must be checked before the reserved-node round trip
# reorders local chains and burns wall-clock time (jobs 1044/1113/1172/1173). Line-number order is
# the only invariant a static self-test can hold on shell source; a regression here reintroduces
# that cascade instead of failing loudly.
_remote_node_regressions_run_last_self_test() {
    local here="$1" gate_line call_line
    gate_line=$(grep -n 'no sync-gate hold in the dashboard log' "$here/phases/provision-initial.sh" | cut -d: -f1 | head -1)
    call_line=$(grep -n 'phase_provision_remote_node_regressions "' "$here/phases/provision-initial.sh" | cut -d: -f1 | head -1)
    [ -n "$gate_line" ] && [ -n "$call_line" ] && [ "$call_line" -gt "$gate_line" ]
}

_approval_self_test() {
    local f=0 here
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    _config_version_asset_self_test || f=$((f + 1))
    _config_version_asset_phase_self_test || f=$((f + 1))
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
    _dashboard_password_repoint_applied_self_test || f=$((f + 1))
    _password_fixture_self_test || f=$((f + 1))
    _control_preview_retry_self_test || f=$((f + 1))
    _password_commit_via_host_self_test || f=$((f + 1))
    _reserved_node_preview_payload_self_test >/dev/null || f=$((f + 1))
    grep -Fq 'phase_provision_sensitive_regressions "$pv_user" "$pv_pass" || bad' "$here/phases/provision-initial.sh" || f=$((f + 1))
    # #2333: the reserved-node round trip must stay AFTER the sync-gate-hold checks, not folded
    # back into phase_provision_sensitive_regressions above — see provision-initial.sh's comment.
    # A caller here (not just present-and-guarded) would silently reintroduce jobs 1044/1113/1172/
    # 1173's cascade: the round trip's own wall-clock cost would again run BEFORE the checks that
    # need chains still fresh.
    grep -Fq 'phase_provision_remote_node_regressions "$pv_user" "$pv_pass" || bad' "$here/phases/provision-initial.sh" || f=$((f + 1))
    _remote_node_regressions_run_last_self_test "$here" || f=$((f + 1))
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
