#!/usr/bin/env bash
# Host-mediated configuration approval and remote-node consumption (#1959/#1966). Sourced by
# tests/os/run.sh; --self-test covers the pure consumer verdict without a guest or network.
# shellcheck source=tests/os/appliance-approval-verdict.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/appliance-approval-verdict.sh"

APPROVAL_RESTORE_SNAPSHOT=""
# #2076 deleted the guest-side fake Telegram provider this leg used to install (a fake `curl` on
# the control unit's PATH, an owner lock, a bind/quiesce/disarm dance, and a prompt sidecar). A
# sensitive commit no longer contacts Telegram at all, so the leg drives the ordinary authenticated
# control route and needs no privileged loopback identity. What is kept is the restore discipline:
# this phase repoints the appliance at reserved nodes and MUST put the original config back.

# The max-time is not arbitrary and must stay above the dashboard's own answer window (#2060):
# handle_control_* holds the request open until the runner answers or CONTROL_WAIT_S (30s) elapses,
# and only THEN returns 202 with the request id. That id is the only way into the polling loop in
# dashboard_control_request, so a POST that gives up first loses the request entirely — the caller
# gets nothing back and the row reports "no result" for an operation that was merely slow. At 8s
# that was every control operation which does real work: a commit that runs an apply, and doctor on
# an unhealthy box. Their fast siblings (preview, doctor on a healthy box) answered inside 8s and
# passed, which is what made the failures read as the runner losing results.
dashboard_control_post() { # <route> <json-body>; keeps secrets out of curl's argv
    printf '%s' "$2" | dashboard_curl -sSk -m 45 -H 'Content-Type: application/json' \
        -H 'X-Pithead-Control: 1' --data-binary @- "https://$ip/api/control/$1" 2>/dev/null
}
dashboard_config_body() { printf '%s' "$1" | jq -c '{config:.}'; }

remote_node_proposal() { # <config> <monero-host> <rpc> <zmq> <user> <password> <tari-host> <grpc>
    printf '%s\0' "$@" | jq -Rsc 'split("\u0000") as $v | ($v[0] | fromjson) |
        .monero.mode="remote" | .monero.remote={host:$v[1],rpc_port:($v[2]|tonumber),zmq_port:($v[3]|tonumber)} |
        .monero.node_username=$v[4] | .monero.node_password=$v[5] |
        .tari.mode="remote" | .tari.remote={host:$v[6],grpc_port:($v[7]|tonumber)}'
}

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

remote_node_runtime_verdict() { # <monero-host> <rpc> <zmq> <tari-host> <grpc> <p2pool-startup-log>
    local mh="$1" rpc="$2" zmq="$3" th="$4" grpc="$5" snapshot="$6" env cmd flags tari_endpoint started now
    started=$(printf '%s\n' "$snapshot" | sed -n '1s/^PITHEAD_P2POOL_STARTED=//p')
    logs=$(printf '%s\n' "$snapshot" | sed '1d')
    [ -n "$started" ] || return 1
    now=$(_ssh "podman inspect p2pool --format '{{.State.StartedAt}}'" 2>/dev/null | tr -d '\r') || return 1
    [ "$now" = "$started" ] || return 1
    env=$(_ssh "sed -n '/^MONERO_NODE_HOST=/p; /^MONERO_RPC_PORT=/p; /^MONERO_ZMQ_PORT=/p; /^TARI_GRPC_ADDRESS=/p' /data/pithead/.env" 2>/dev/null | tr -d '\r') || return 1
    printf '%s\n' "$env" | grep -qxF "MONERO_NODE_HOST=$mh" || return 1
    printf '%s\n' "$env" | grep -qxF "MONERO_RPC_PORT=$rpc" || return 1
    printf '%s\n' "$env" | grep -qxF "MONERO_ZMQ_PORT=$zmq" || return 1
    printf '%s\n' "$env" | grep -qxF "TARI_GRPC_ADDRESS=$th:$grpc" || return 1
    cmd=$(_ssh "podman inspect p2pool --format '{{json .Config.Cmd}}' | jq -r 'def val(\$name): index(\$name) as \$i | if \$i == null then \"\" else .[\$i+1] // \"\" end; [val(\"--host\"),val(\"--rpc-port\"),val(\"--zmq-port\"),val(\"--merge-mine\")] | @tsv'" 2>/dev/null | tr -d '\r') || return 1
    [ "$cmd" = "$(printf '%s\t%s\t%s\ttari://%s:%s' "$mh" "$rpc" "$zmq" "$th" "$grpc")" ] || return 1
    flags=$(_ssh "podman inspect p2pool --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^P2POOL_FLAGS=//p'" 2>/dev/null | tr -d '\r') || return 1
    tari_endpoint="$th:$grpc"
    case " $flags " in *" --socks5 "* | *" --socks5="*) tari_endpoint="127.0.0.1:$grpc" ;; esac
    tari_endpoint_roundtrip_verdict "$logs" "$tari_endpoint" || return 1
    now=$(_ssh "podman inspect p2pool --format '{{.State.StartedAt}}'" 2>/dev/null | tr -d '\r') || return 1
    [ "$now" = "$started" ]
}

p2pool_current_startup_merge_lines() {
    local started
    started=$(_ssh "podman inspect p2pool --format '{{.State.StartedAt}}'" 2>/dev/null | tr -d '\r')
    [ -n "$started" ] || return 1
    printf 'PITHEAD_P2POOL_STARTED=%s\n' "$started"
    _ssh "podman logs --since '$started' p2pool 2>&1 | head -n $MM_WINDOW_LINES | grep -a MergeMiningClientTari || true" 2>/dev/null
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
    local mh="${PITHEAD_OS_MONERO_NODE_HOST:-}" rpc="${PITHEAD_OS_MONERO_RPC_PORT:-}" zmq="${PITHEAD_OS_MONERO_ZMQ_PORT:-}"
    local mu="${PITHEAD_OS_MONERO_NODE_USERNAME:-}" mp="${PITHEAD_OS_MONERO_NODE_PASSWORD:-}"
    local th="${PITHEAD_OS_TARI_NODE_HOST:-}" grpc="${PITHEAD_OS_TARI_GRPC_PORT:-}" logs tries node_ok

    # An unreadable dashboard is an UPSTREAM condition, not a verdict on this leg. #2060's
    # host-mediated-hostname row leaves the dashboard unreadable, and a leg that reports
    # "sensitive config failed" there hangs a Telegram-shaped label on a hostname-shaped defect —
    # exactly what happened to the #1929 tari leg on 2026-09-11. Say what was actually observed.
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
    # The audit must name THIS request and record the signed-in dashboard actor. It must NOT carry
    # an approver: that field had exactly one writer, the removed Telegram verifier (#2076).
    if printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null &&
        printf '%s\n' "$audit" | jq -se --arg id "$rid" 'any(.[]; .id == $id and .status == "applied" and (.approver // "") == "")' >/dev/null &&
        assert_appliance_hostname_identity fixture-next "confirmed day-two hostname" "$DASH_USER" "$DASH_PASS"; then
        ok "a confirmed day-two hostname commit applies, audits without an approver, and converges live identity"
    else
        bad "confirmed hostname commit did not bind apply, a clean audit row and live identity ($(approval_bind_payload "$result" "$audit" "$rid"))"
        return
    fi

    live=$(sensitive_live_config) || return
    proposed=$(printf '%s' "$live" | jq -c '.dashboard.auth.password = "os1966-physical-only"')
    sensitive_preview "$(dashboard_config_body "$proposed")" || return
    preview=$APPROVAL_PREVIEW rid=$APPROVAL_REQUEST_ID
    result=$(approval_commit "$rid")
    if printf '%s' "$result" | jq -e '.status == "rejected" and (.error | contains("configuration stick"))' >/dev/null &&
        dashboard_curl -fsSk -m 8 "https://$ip/api/config" >/dev/null 2>&1; then
        ok "host approval cannot cross the physical-presence-only dashboard-password boundary"
    else
        bad "physical-presence-only config crossed approval or replaced the live dashboard login"
        return
    fi

    if [ -z "$mh" ] || [ -z "$rpc" ] || [ -z "$zmq" ] || [ -z "$th" ] || [ -z "$grpc" ]; then
        bad "reserved-node inputs are missing — set PITHEAD_OS_MONERO_NODE_HOST/RPC_PORT/ZMQ_PORT and PITHEAD_OS_TARI_NODE_HOST/GRPC_PORT for the required consumer proof"
        return
    fi
    for port in "$rpc" "$zmq" "$grpc"; do
        case "$port" in *[!0-9]* | "") port=0 ;; esac
        if [ "$port" -lt 1 ] 2>/dev/null || [ "$port" -gt 65535 ] 2>/dev/null; then
            bad "reserved-node ports must be decimal integers from 1 through 65535"
            return
        fi
    done
    live=$(sensitive_live_config) || return
    proposed=$(remote_node_proposal "$live" "$mh" "$rpc" "$zmq" "$mu" "$mp" "$th" "$grpc") || {
        bad "reserved-node proposal could not be constructed"
        return
    }
    sensitive_preview "$(dashboard_config_body "$proposed")" || return
    preview=$APPROVAL_PREVIEW
    if ! printf '%s' "$preview" | jq -e --arg mh "$mh" --arg th "$th" '
        .status == "previewed" and .destructive == true and .approval_required == true and
        any(.preview_values[]; .key == "monero.remote.host" and .new == $mh) and
        any(.preview_values[]; .key == "tari.remote.host" and .new == $th)' >/dev/null; then
        bad "reserved-node preview did not expose endpoints behind the combined approval gate"
        return
    fi
    rid=$APPROVAL_REQUEST_ID
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id,approve:true,payout_suffixes:{}}')")
    if printf '%s' "$result" | jq -e '.status == "rejected" and (.error | contains("type APPLY"))' >/dev/null; then
        ok "reachable-node commit is refused before probing or approval without typed APPLY"
    else
        bad "reachable-node commit crossed the typed confirmation gate"
        return
    fi
    sensitive_preview "$(dashboard_config_body "$proposed")" || return
    preview=$APPROVAL_PREVIEW rid=$APPROVAL_REQUEST_ID
    approval_capture_restore_snapshot || {
        bad "could not preserve the original raw configuration for guaranteed restore"
        return
    }
    result=$(approval_commit "$rid")
    if ! printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null; then
        bad "host preflight refused the reserved nodes"
        return
    fi
    node_ok=1
    audit=$(_ssh "tail -n 20 /data/pithead/data/control/audit/control.log" 2>/dev/null)
    printf '%s\n' "$audit" | jq -se --arg id "$rid" 'any(.[];
        .id == $id and .status == "applied" and (.approver // "") == "")' >/dev/null || {
        bad "reserved-node audit did not bind the current request and applied status, or carried an approver"
        node_ok=0
    }
    # The preview the operator reads is now the only place these endpoints are shown before they
    # are committed, so it carries the disclosure duty the removed Telegram prompt used to: name
    # both endpoints in full, and never the node credentials that travel in the same change.
    if ! printf '%s' "$preview" | jq -e --arg mh "$mh" --arg th "$th" '
        any(.preview_values[]; .key == "monero.remote.host" and .new == $mh) and
        any(.preview_values[]; .key == "tari.remote.host" and .new == $th)' >/dev/null; then
        bad "reserved-node preview omitted an endpoint the operator must see before confirming"
        node_ok=0
    fi
    if { [ -n "$mu" ] && case "$preview" in *"$mu"*) true ;; *) false ;; esac } ||
        { [ -n "$mp" ] && case "$preview" in *"$mp"*) true ;; *) false ;; esac } then
        bad "reserved-node preview exposed a Monero node credential"
        node_ok=0
    else
        ok "reserved-node preview exposes node endpoints without node credentials"
    fi
    tries=0 logs=""
    while [ "$tries" -lt 60 ]; do
        logs=$(p2pool_current_startup_merge_lines)
        remote_node_runtime_verdict "$mh" "$rpc" "$zmq" "$th" "$grpc" "$logs" && break
        tries=$((tries + 1))
        sleep 10
    done
    if [ "$tries" -lt 60 ]; then
        ok "approved endpoints passed host preflight and p2pool consumed Tari chain_id from the current startup"
    else
        bad "approved endpoints landed but current p2pool never proved the Tari chain_id round trip ($(mm_roundtrip_verdict "$logs"))"
        node_ok=0
    fi

    if approval_restore_pending; then
        ok "approved-node fixture restored the original local-node configuration"
    else
        bad "approved-node fixture could not restore the original node configuration"
    fi
    [ "$node_ok" -eq 1 ] || return 1
}

_approval_self_test() {
    local f=0
    mm_roundtrip_verdict 'MergeMiningClientTari tari://127.0.0.1:18142 uses chain_id 0123456789abcdef' >/dev/null || f=$((f + 1))
    mm_roundtrip_verdict 'MergeMiningClientTari worker thread ready' >/dev/null && f=$((f + 1))
    tari_endpoint_roundtrip_verdict 'MergeMiningClientTari tari://node.fixture:18142 uses chain_id 0123456789abcdef' 'node.fixture:18142' || f=$((f + 1))
    tari_endpoint_roundtrip_verdict 'MergeMiningClientTari tari://old.fixture:18142 uses chain_id 0123456789abcdef' 'node.fixture:18142' && f=$((f + 1))
    _control_request_transport_self_test || f=$((f + 1))
    # Called from HERE, not from _approval_bind_payload_self_test: that one is also driven
    # standalone by tests/os/selftest-row-payloads.sh, which sources this verdict file WITHOUT
    # provision-browser-submit.sh — so `dashboard_control_request` does not exist there and the
    # check dies as a missing command rather than a verdict.
    _control_request_lost_response_self_test || f=$((f + 1))
    _approval_bind_payload_self_test >/dev/null || f=$((f + 1))
    _runtime_epoch_self_test || f=$((f + 1))
    grep -Fq 'phase_provision_sensitive_regressions "$pv_user" "$pv_pass" || bad' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/phases/provision-initial.sh" || f=$((f + 1))
    [ "$f" -eq 0 ] || {
        printf 'appliance-config-approval-leg self-test FAILED: %s checks\n' "$f"
        return 1
    }
    printf 'appliance-config-approval-leg self-test passed\n'
}
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --self-test ]; then
    set -uo pipefail
    # shellcheck source=tests/os/provision-browser-submit.sh
    . "$(cd "$(dirname "$0")" && pwd)/provision-browser-submit.sh"
    # shellcheck source=tests/integration/lib/mergemine-probe.sh
    . "$(cd "$(dirname "$0")/../integration/lib" && pwd)/mergemine-probe.sh"
    _approval_self_test
fi
