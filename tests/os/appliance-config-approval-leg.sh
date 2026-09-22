#!/usr/bin/env bash
# Host-mediated configuration approval and remote-node consumption (#1959/#1966). Sourced by
# tests/os/run.sh; --self-test covers the pure consumer verdict without a guest or network.
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

remote_node_proposal() { # <config> <monero-host> <rpc> <zmq> <user> <password> <tari-host> <grpc>
    # Blank credentials preserve their masked sentinels; nonblank ones join the atomic endpoint
    # proposal behind the same typed confirmation (#2297/#2333).
    printf '%s\0' "$@" | jq -Rsc 'split("\u0000") as $v | ($v[0] | fromjson) |
        .monero.mode="remote" | .monero.remote={host:$v[1],rpc_port:($v[2]|tonumber),zmq_port:($v[3]|tonumber)} |
        (if $v[4] != "" then .monero.node_username=$v[4] else . end) |
        (if $v[5] != "" then .monero.node_password=$v[5] else . end) |
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
    # #2333: MM_WINDOW_LINES (tests/integration/lib/mergemine-probe.sh) is sized against a fast
    # first connection — the chain_id line lands within the first ~70 lines there. A remote node
    # p2pool has never dialed before can take far longer, and every retry's capped read then
    # identically misses a line that eventually lands past the cap: "never connected" and
    # "connected too late for the window" become indistinguishable. Uncapped here, unlike that
    # shared helper's own callers, since this leg's own reserved node is exactly that slow case.
    _ssh "podman logs --since '$started' p2pool 2>&1 | grep -a MergeMiningClientTari || true" 2>/dev/null
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

local_node_login_runtime_verdict() {
    # shellcheck disable=SC2016 # this script is intentionally evaluated by the guest shell
    _ssh 'set -eu
podman inspect monerod dashboard p2pool |
    jq -e --slurpfile cfg /data/pithead/config.json '\''
        ($cfg[0].monero.node_username // "") as $u | ($cfg[0].monero.node_password // "") as $p |
        def container($name): map(select(.Name == ("/" + $name)))[0];
        def has_login($name): container($name).Config.Env |
            index("MONERO_NODE_USERNAME=" + $u) != null and index("MONERO_NODE_PASSWORD=" + $p) != null;
        (container("p2pool").Config.Cmd) as $cmd | ($cmd | index("--rpc-login")) as $i |
        $u != "" and $p != "" and has_login("monerod") and has_login("dashboard") and
        $i != null and $cmd[$i+1] == ($u + ":" + $p)
    '\'' >/dev/null'
}

local_node_login_edit() { # <config-path> <env-key> <value> <label>
    local live proposed preview result rid
    live=$(sensitive_live_config) || return 1
    proposed=$(printf '%s' "$live" | jq -c --arg value "$3" "$1 = \$value") || return 1
    sensitive_preview "$(dashboard_config_body "$proposed")" || return 1
    preview=$APPROVAL_PREVIEW rid=$APPROVAL_REQUEST_ID
    printf '%s' "$preview" | jq -e --arg key "$2" \
        '.status == "previewed" and .destructive == true and any(.changes[]?; .key == $key and .flag == "CONFIRM")' >/dev/null || return 1
    result=$(approval_commit "$rid")
    printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null || return 1
    sensitive_live_config >/dev/null && local_node_login_runtime_verdict || return 1
    ok "standalone local $4 preserves the coupled node login and authenticated dashboard access"
}

phase_provision_sensitive_regressions() { # <dashboard-user> <dashboard-password>
    local DASH_USER="$1" DASH_PASS="$2" live proposed preview result rid before after audit
    local mh="${PITHEAD_OS_MONERO_NODE_HOST:-}" rpc="${PITHEAD_OS_MONERO_RPC_PORT:-}" zmq="${PITHEAD_OS_MONERO_ZMQ_PORT:-}"
    local mu="${PITHEAD_OS_MONERO_NODE_USERNAME:-}" mp="${PITHEAD_OS_MONERO_NODE_PASSWORD:-}"
    local th="${PITHEAD_OS_TARI_NODE_HOST:-}" grpc="${PITHEAD_OS_TARI_GRPC_PORT:-}" logs tries node_ok
    local status destructive approval_required mh_shown th_shown login_warned env_now cmd_now
    local env_ok cmd_ok direct_ok bridged_ok flags_now socks5_now

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
    # A restart can lose the result after the hostname already applied; probe identity once.
    local identity_landed=unknown identity_evidence=
    if [ -z "$result" ]; then
        if identity_evidence=$(assert_appliance_hostname_identity fixture-next "confirmed day-two hostname" "$DASH_USER" "$DASH_PASS"); then
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
        [ -z "$identity_evidence" ] || printf '%s\n' "$identity_evidence"
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
    approval_capture_restore_snapshot || {
        bad "could not preserve the original raw configuration for guaranteed restore"
        return
    }

    local_node_login_edit '.monero.node_username' MONERO_NODE_USERNAME os2333-local-user "username edit" || {
        bad "standalone local node username edit did not preserve runtime access"
        return 1
    }
    local_node_login_edit '.monero.node_password' MONERO_NODE_PASSWORD os2333-local-pass "password edit" || {
        bad "standalone local node password edit did not preserve runtime access"
        return 1
    }

    # Endpoint and login land through one confirmed proposal (#2333/#2367). Clearnet keeps the
    # reserved private Tari endpoint out of P2Pool's Tor SOCKS path (#165).
    proposed=$(remote_node_proposal "$live" "$mh" "$rpc" "$zmq" "$mu" "$mp" "$th" "$grpc" | jq -c '.p2pool.clearnet = true') || {
        bad "reserved-node proposal could not be constructed"
        return
    }
    sensitive_preview "$(dashboard_config_body "$proposed")" || return
    preview=$APPROVAL_PREVIEW
    status=$(printf '%s' "$preview" | jq -r '.status // "unreadable"')
    destructive=$(printf '%s' "$preview" | jq -r '.destructive // false')
    approval_required=$(printf '%s' "$preview" | jq -r '.approval_required // false')
    mh_shown=$(printf '%s' "$preview" | jq -e --arg mh "$mh" 'any(.preview_values[]?; .key == "monero.remote.host" and .new == $mh)' >/dev/null 2>&1 && echo true || echo false)
    th_shown=$(printf '%s' "$preview" | jq -e --arg th "$th" 'any(.preview_values[]?; .key == "tari.remote.host" and .new == $th)' >/dev/null 2>&1 && echo true || echo false)
    login_warned=true
    if [ -n "$mu" ] && ! printf '%s' "$preview" | jq -e 'any(.changes[]?; .key == "MONERO_NODE_USERNAME" and .flag == "CONFIRM")' >/dev/null 2>&1; then
        login_warned=false
    fi
    if [ -n "$mp" ] && ! printf '%s' "$preview" | jq -e 'any(.changes[]?; .key == "MONERO_NODE_PASSWORD" and .flag == "CONFIRM")' >/dev/null 2>&1; then
        login_warned=false
    fi
    if [ "$status" = previewed ] && [ "$destructive" = true ] && [ "$approval_required" = true ] &&
        [ "$mh_shown" = true ] && [ "$th_shown" = true ] && [ "$login_warned" = true ]; then
        ok "reserved-node preview warns about the login and exposes endpoints behind the combined approval gate"
    else
        bad "reserved-node preview did not warn/expose correctly (status=$status destructive=$destructive approval_required=$approval_required monero_host_shown=$mh_shown tari_host_shown=$th_shown login_warned=$login_warned; $(reserved_node_preview_payload "$preview"))"
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
    result=$(approval_commit "$rid")
    if ! printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null; then
        bad "host preflight refused the reserved nodes ($(printf '%s' "$result" | jq -c '{status,error}' 2>/dev/null || printf 'unreadable result'))"
        return
    fi
    node_ok=1
    audit=$(_ssh "tail -n 20 /data/pithead/data/control/audit/control.log" 2>/dev/null)
    printf '%s\n' "$audit" | jq -se --arg id "$rid" 'any(.[];
        .id == $id and .status == "applied" and (.approver // "") == "")' >/dev/null || {
        bad "reserved-node audit did not bind the current request and applied status, or carried an approver"
        node_ok=0
    }
    # The preview names both endpoints and warns about the login without exposing its value.
    if ! printf '%s' "$preview" | jq -e --arg mh "$mh" --arg th "$th" '
        any(.preview_values[]; .key == "monero.remote.host" and .new == $mh) and
        any(.preview_values[]; .key == "tari.remote.host" and .new == $th)' >/dev/null; then
        bad "reserved-node preview omitted an endpoint the operator must see before confirming ($(reserved_node_preview_payload "$preview"))"
        node_ok=0
    fi
    if { [ -n "$mu" ] && case "$preview" in *"$mu"*) true ;; *) false ;; esac } ||
        { [ -n "$mp" ] && case "$preview" in *"$mp"*) true ;; *) false ;; esac } then
        bad "reserved-node preview echoed the Monero node credential's value"
        node_ok=0
    else
        ok "reserved-node preview warns about the login change without echoing its value"
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
        env_ok=false cmd_ok=false direct_ok=false bridged_ok=false
        env_now=$(_ssh "sed -n '/^MONERO_NODE_HOST=/p; /^MONERO_RPC_PORT=/p; /^MONERO_ZMQ_PORT=/p; /^TARI_GRPC_ADDRESS=/p' /data/pithead/.env" 2>/dev/null | tr -d '\r')
        printf '%s\n' "$env_now" | grep -qxF "MONERO_NODE_HOST=$mh" &&
            printf '%s\n' "$env_now" | grep -qxF "MONERO_RPC_PORT=$rpc" &&
            printf '%s\n' "$env_now" | grep -qxF "MONERO_ZMQ_PORT=$zmq" &&
            printf '%s\n' "$env_now" | grep -qxF "TARI_GRPC_ADDRESS=$th:$grpc" && env_ok=true
        cmd_now=$(_ssh "podman inspect p2pool --format '{{json .Config.Cmd}}' | jq -r 'def val(\$name): index(\$name) as \$i | if \$i == null then \"\" else .[\$i+1] // \"\" end; [val(\"--host\"),val(\"--rpc-port\"),val(\"--zmq-port\"),val(\"--merge-mine\")] | @tsv'" 2>/dev/null | tr -d '\r')
        [ "$cmd_now" = "$(printf '%s\t%s\t%s\ttari://%s:%s' "$mh" "$rpc" "$zmq" "$th" "$grpc")" ] && cmd_ok=true
        flags_now=$(_ssh "podman inspect p2pool --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^P2POOL_FLAGS=//p'" 2>/dev/null | tr -d '\r')
        socks5_now=false
        case " $flags_now " in *" --socks5 "* | *" --socks5="*) socks5_now=true ;; esac
        tari_endpoint_roundtrip_verdict "$logs" "$th:$grpc" && direct_ok=true
        tari_endpoint_roundtrip_verdict "$logs" "127.0.0.1:$grpc" && bridged_ok=true
        started_now=$(_ssh "podman inspect p2pool --format '{{.State.StartedAt}}'" 2>/dev/null | tr -d '\r')
        restarted=false
        [ "$started_now" = "$(printf '%s\n' "$logs" | sed -n '1s/^PITHEAD_P2POOL_STARTED=//p')" ] || restarted=true
        bad "approved endpoints landed but current p2pool never proved the Tari chain_id round trip (provider=${CI_NODE_PROVIDER:-unknown} env_ok=$env_ok cmd_ok=$cmd_ok p2pool_socks5=$socks5_now p2pool_restarted=$restarted tari_rpc=chain_id_absent roundtrip_direct=$direct_ok roundtrip_bridged=$bridged_ok; mm log: $(mm_roundtrip_verdict "$logs"))"
        node_ok=0
    fi

    if approval_restore_pending; then
        ok "approved-node fixture restored the original local-node configuration"
    else
        bad "approved-node fixture could not restore the original node configuration"
    fi
    [ "$node_ok" -eq 1 ] || return 1
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

# #2297: a blank monero-node-username/password arg must leave monero.node_username/node_password
# UNTOUCHED, so a live {"__secret__":true} sentinel survives to control_preview's restore — see the
# comment on remote_node_proposal itself for why an overwrite to "" defeats that restore and trips
# the credential perimeter. A NON-blank arg must still land (an operator-supplied real credential
# for a node that DOES need auth is exactly what this path exists to carry).
_remote_node_proposal_self_test() {
    local f=0 live out
    live='{"monero":{"node_username":{"__secret__":true},"node_password":{"__secret__":true}}}'
    out=$(remote_node_proposal "$live" mh 1 2 "" "" th 3)
    case "$out" in *'"__secret__":true'*'"__secret__":true'*) ;; *) f=$((f + 1)) ;; esac
    out=$(printf '%s' "$out" | jq -r '.monero.node_username.__secret__, .monero.node_password.__secret__' 2>/dev/null | tr '\n' ' ')
    [ "$out" = "true true " ] || f=$((f + 1))
    out=$(remote_node_proposal "$live" mh 1 2 realuser realpass th 3 | jq -r '.monero.node_username, .monero.node_password' 2>/dev/null | tr '\n' ' ')
    [ "$out" = "realuser realpass " ] || f=$((f + 1))
    [ "$f" -eq 0 ] || {
        printf 'remote-node-proposal self-test FAILED: %s checks\n' "$f"
        return 1
    }
    printf 'remote-node-proposal self-test passed\n'
}

_approval_self_test() {
    local f=0 here
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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
    _hostname_landed_fallback_self_test || f=$((f + 1))
    _restore_waits_for_control_drain_self_test || f=$((f + 1))
    grep -Fq '_control_requests_drained || {' "$here/appliance-dashboard-exposure-leg.sh" || f=$((f + 1))
    _physical_presence_password_refusal_self_test || f=$((f + 1))
    _reserved_node_preview_payload_self_test >/dev/null || f=$((f + 1))
    _runtime_epoch_self_test || f=$((f + 1))
    _remote_node_proposal_self_test || f=$((f + 1))
    grep -Fq 'phase_provision_sensitive_regressions "$pv_user" "$pv_pass" || bad' "$here/phases/provision-initial.sh" || f=$((f + 1))
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
