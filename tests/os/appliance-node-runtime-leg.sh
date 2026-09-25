#!/usr/bin/env bash
# Confirm-gated Monero login edits and reserved-node runtime proof (#2333). Loaded by
# appliance-config-approval-leg.sh after the shared approval helpers.

REMOTE_NODE_RUNTIME_REASON="not-run"

remote_node_proposal() { # <config> <monero-host> <rpc> <zmq> <user> <password> <tari-host> <grpc>
    # Blank credentials preserve their masked sentinels; nonblank ones join the atomic endpoint
    # proposal behind the same typed confirmation (#2297/#2333).
    printf '%s\0' "$@" | jq -Rsc 'split("\u0000") as $v | ($v[0] | fromjson) |
        .monero.mode="remote" | .monero.remote={host:$v[1],rpc_port:($v[2]|tonumber),zmq_port:($v[3]|tonumber)} |
        (if $v[4] != "" then .monero.node_username=$v[4] else . end) |
        (if $v[5] != "" then .monero.node_password=$v[5] else . end) |
        .tari.mode="remote" | .tari.remote={host:$v[6],grpc_port:($v[7]|tonumber)}'
}

remote_node_runtime_verdict() { # <monero-host> <rpc> <zmq> <tari-host> <grpc> <p2pool-startup-log>
    local mh="$1" rpc="$2" zmq="$3" th="$4" grpc="$5" snapshot="$6" env cmd flags logs tari_endpoint started now
    started=$(printf '%s\n' "$snapshot" | sed -n '1s/^PITHEAD_P2POOL_STARTED=//p')
    logs=$(printf '%s\n' "$snapshot" | sed '1d')
    REMOTE_NODE_RUNTIME_REASON="startup-epoch-missing"
    [ -n "$started" ] || return 1
    REMOTE_NODE_RUNTIME_REASON="container-epoch-unreadable"
    now=$(_ssh "podman inspect p2pool --format '{{.State.StartedAt}}'" 2>/dev/null | tr -d '\r') || return 1
    REMOTE_NODE_RUNTIME_REASON="container-restarted"
    [ "$now" = "$started" ] || return 1
    REMOTE_NODE_RUNTIME_REASON="environment-unreadable"
    env=$(_ssh "sed -n '/^MONERO_NODE_HOST=/p; /^MONERO_RPC_PORT=/p; /^MONERO_ZMQ_PORT=/p; /^TARI_GRPC_ADDRESS=/p' /data/pithead/.env" 2>/dev/null | tr -d '\r') || return 1
    REMOTE_NODE_RUNTIME_REASON="monero-host-mismatch"
    printf '%s\n' "$env" | grep -qxF "MONERO_NODE_HOST=$mh" || return 1
    REMOTE_NODE_RUNTIME_REASON="monero-rpc-port-mismatch"
    printf '%s\n' "$env" | grep -qxF "MONERO_RPC_PORT=$rpc" || return 1
    REMOTE_NODE_RUNTIME_REASON="monero-zmq-port-mismatch"
    printf '%s\n' "$env" | grep -qxF "MONERO_ZMQ_PORT=$zmq" || return 1
    REMOTE_NODE_RUNTIME_REASON="tari-address-mismatch"
    printf '%s\n' "$env" | grep -qxF "TARI_GRPC_ADDRESS=$th:$grpc" || return 1
    REMOTE_NODE_RUNTIME_REASON="command-unreadable"
    cmd=$(_ssh "podman inspect p2pool --format '{{json .Config.Cmd}}' | jq -r 'def val(\$name): index(\$name) as \$i | if \$i == null then \"\" else .[\$i+1] // \"\" end; [val(\"--host\"),val(\"--rpc-port\"),val(\"--zmq-port\"),val(\"--merge-mine\")] | @tsv'" 2>/dev/null | tr -d '\r') || return 1
    REMOTE_NODE_RUNTIME_REASON="command-mismatch"
    [ "$cmd" = "$(printf '%s\t%s\t%s\ttari://%s:%s' "$mh" "$rpc" "$zmq" "$th" "$grpc")" ] || return 1
    REMOTE_NODE_RUNTIME_REASON="flags-unreadable"
    flags=$(_ssh "podman inspect p2pool --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^P2POOL_FLAGS=//p'" 2>/dev/null | tr -d '\r') || return 1
    tari_endpoint="$th:$grpc"
    case " $flags " in *" --socks5 "* | *" --socks5="*) tari_endpoint="127.0.0.1:$grpc" ;; esac
    REMOTE_NODE_RUNTIME_REASON="tari-roundtrip-missing"
    tari_endpoint_roundtrip_verdict "$logs" "$tari_endpoint" || return 1
    REMOTE_NODE_RUNTIME_REASON="container-epoch-unreadable"
    now=$(_ssh "podman inspect p2pool --format '{{.State.StartedAt}}'" 2>/dev/null | tr -d '\r') || return 1
    REMOTE_NODE_RUNTIME_REASON="container-restarted"
    [ "$now" = "$started" ] || return 1
    REMOTE_NODE_RUNTIME_REASON="ok"
}

p2pool_current_startup_merge_lines() {
    local started since
    started=$(_ssh "podman inspect p2pool --format '{{.State.StartedAt}}'" 2>/dev/null | tr -d '\r')
    [ -n "$started" ] || return 1
    printf 'PITHEAD_P2POOL_STARTED=%s\n' "$started"
    # Uncapped, unlike MM_WINDOW_LINES (mergemine-probe.sh): a first dial to a reserved node can
    # land its chain_id line past any cap, making "never connected" and "connected late" look alike.
    # podman's --since refuses StartedAt's own Go form; the refusal went to grep and read "absent".
    since=$(printf '%s\n' "$started" | mm_rfc3339)
    _ssh "podman logs --since '$since' p2pool 2>&1 | grep -a MergeMiningClientTari || true" 2>/dev/null
}

allowlisted_node_readiness() {
    jq -c '{monero_rpc:(.monero_rpc == true),monero_synced:(.monero_synced == true),
        monero_height:(.monero_height|numbers // 0),tari_rpc:(.tari_rpc == true),
        tari_synced:(.tari_synced == true),tari_height:(.tari_height|numbers // 0)}'
}

guest_node_readiness() { # <monero-host> <rpc-port>
    # Existing authenticated clients, from the guest network; never emit endpoints, credentials,
    # exceptions, or raw responses.
    local monero_url_q
    printf -v monero_url_q %q "http://$1:$2"
    SSH_TIMEOUT=15 _ssh "podman exec -e PROBE_MONERO_URL=$monero_url_q dashboard python -c 'import asyncio,json,os; from mining_dashboard.client.monero.monero_client import MoneroClient; from mining_dashboard.client.tari.tari_client import TariClient; m=MoneroClient(url=os.environ[\"PROBE_MONERO_URL\"]).get_info(); t=asyncio.run(TariClient().get_sync_status()); print(json.dumps({\"monero_rpc\":m is not None,\"monero_synced\":bool(m and m.get(\"synchronized\")),\"monero_height\":int((m or {}).get(\"height\",0) or 0),\"tari_rpc\":bool(t.get(\"reachable\")),\"tari_synced\":bool(t.get(\"reachable\") and not t.get(\"is_syncing\")),\"tari_height\":int(t.get(\"current\",0) or 0)}))'" 2>/dev/null |
        allowlisted_node_readiness
}

# Input: `podman inspect monerod dashboard p2pool`; $cfg: config.json. Podman's .Name carries no
# leading slash (Docker's does), so accept both rather than silently match nothing.
# shellcheck disable=SC2016 # jq program, not shell
LOCAL_NODE_LOGIN_JQ='($cfg[0].monero.node_username // "") as $u | ($cfg[0].monero.node_password // "") as $p |
    def container($name): map(select((.Name | ltrimstr("/")) == $name))[0];
    def has_login($name): container($name).Config.Env |
        index("MONERO_NODE_USERNAME=" + $u) != null and index("MONERO_NODE_PASSWORD=" + $p) != null;
    (container("p2pool").Config.Cmd) as $cmd | ($cmd | index("--rpc-login")) as $i |
    $u != "" and $p != "" and has_login("monerod") and has_login("dashboard") and
    $i != null and $cmd[$i+1] == ($u + ":" + $p)'
LOCAL_NODE_LOGIN_REASON="not-run"

local_node_login_runtime_verdict() {
    local jq_q
    printf -v jq_q %q "$(printf '%s' "$LOCAL_NODE_LOGIN_JQ" | tr '\n' ' ')" # one line: no $'' quoting
    _ssh "podman inspect monerod dashboard p2pool | jq -e --slurpfile cfg /data/pithead/config.json $jq_q >/dev/null"
}

local_node_login_edit() { # <config-path> <env-key> <value> <label>
    local live proposed preview result rid
    LOCAL_NODE_LOGIN_REASON="live-config-unreadable"
    live=$(sensitive_live_config) || return 1
    LOCAL_NODE_LOGIN_REASON="proposal-unbuildable"
    proposed=$(printf '%s' "$live" | jq -c --arg value "$3" "$1 = \$value") || return 1
    LOCAL_NODE_LOGIN_REASON="preview-failed"
    sensitive_preview "$(dashboard_config_body "$proposed")" || return 1
    preview=$APPROVAL_PREVIEW rid=$APPROVAL_REQUEST_ID
    LOCAL_NODE_LOGIN_REASON="preview-not-confirm-gated"
    printf '%s' "$preview" | jq -e --arg key "$2" \
        '.status == "previewed" and .destructive == true and any(.changes[]?; .key == $key and .flag == "CONFIRM")' >/dev/null || return 1
    result=$(approval_commit "$rid")
    LOCAL_NODE_LOGIN_REASON="commit-$(printf '%s' "$result" | jq -r '.status // "unreadable"' 2>/dev/null || printf unreadable)"
    printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null || return 1
    LOCAL_NODE_LOGIN_REASON="dashboard-unreadable-after-apply"
    sensitive_live_config >/dev/null || return 1
    LOCAL_NODE_LOGIN_REASON="runtime-login-mismatch"
    local_node_login_runtime_verdict || return 1
    LOCAL_NODE_LOGIN_REASON="ok"
    ok "standalone local $4 preserves the coupled node login and authenticated dashboard access"
}

# p2pool.clearnet (#165) keeps the reserved private Tari endpoint out of P2Pool's Tor SOCKS path,
# which cannot reach a LAN address. On an appliance it is fixed at setup and never committable from
# the dashboard, so the fixture sets it host-side, the way "Set up again" would, before the
# dashboard proposal that carries only the node change.
reserved_node_clearnet_fixture() {
    _control_requests_drained || return 1 # the apply restarts the control runner (#2094)
    _ssh 'set -euo pipefail
cd /data/pithead
jq ".p2pool.clearnet = true" config.json >config.json.os2333-clearnet
chmod 600 config.json.os2333-clearnet
mv config.json.os2333-clearnet config.json
./pithead apply -y >/dev/null
jq -e ".p2pool.clearnet == true" config.json >/dev/null'
}

# SC2034: dashboard_curl reads DASH_USER/DASH_PASS from this frame (dynamic scope; job 1182).
# shellcheck disable=SC2034
phase_provision_remote_node_regressions() { # <dashboard-user> <dashboard-password>
    local DASH_USER="$1" DASH_PASS="$2" rc=0
    _reserved_node_regressions || rc=$?
    # Every exit, early or not, hands the later legs the original config, not the edited login.
    [ -n "${APPROVAL_RESTORE_SNAPSHOT:-}" ] || return "$rc"
    if approval_restore_pending; then
        ok "approved-node fixture restored the original local-node configuration"
    else
        bad "approved-node fixture could not restore the original node configuration"
        rc=1
    fi
    return "$rc"
}

_reserved_node_regressions() {
    local live proposed preview result rid audit logs tries node_ok readiness
    local mh="${PITHEAD_OS_MONERO_NODE_HOST:-}" rpc="${PITHEAD_OS_MONERO_RPC_PORT:-}" zmq="${PITHEAD_OS_MONERO_ZMQ_PORT:-}"
    local mu="${PITHEAD_OS_MONERO_NODE_USERNAME:-}" mp="${PITHEAD_OS_MONERO_NODE_PASSWORD:-}"
    local th="${PITHEAD_OS_TARI_NODE_HOST:-}" grpc="${PITHEAD_OS_TARI_GRPC_PORT:-}"
    local status destructive approval_required mh_shown th_shown login_warned

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
    live=$(sensitive_live_config) || { bad "reserved-node leg NOT exercised: the dashboard never served /api/config"; return 1; }
    approval_capture_restore_snapshot || {
        bad "could not preserve the original raw configuration for guaranteed restore"
        return
    }

    local_node_login_edit '.monero.node_username' MONERO_NODE_USERNAME os2333-local-user "username edit" || {
        bad "standalone local node username edit did not preserve runtime access (step=$LOCAL_NODE_LOGIN_REASON)"
        return 1
    }
    local_node_login_edit '.monero.node_password' MONERO_NODE_PASSWORD os2333-local-pass "password edit" || {
        bad "standalone local node password edit did not preserve runtime access (step=$LOCAL_NODE_LOGIN_REASON)"
        return 1
    }

    reserved_node_clearnet_fixture || {
        bad "reserved-node fixture could not set p2pool.clearnet host-side"
        return 1
    }
    # Re-read after the fixture: a proposal built on the stale config would revert clearnet.
    live=$(sensitive_live_config) || {
        bad "dashboard config unreadable after the clearnet fixture"
        return 1
    }
    # Endpoint and login land through one confirmed proposal (#2333/#2367).
    proposed=$(remote_node_proposal "$live" "$mh" "$rpc" "$zmq" "$mu" "$mp" "$th" "$grpc") || {
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
        readiness=$(guest_node_readiness "$mh" "$rpc" || printf '{"monero_rpc":false,"monero_synced":false,"monero_height":0,"tari_rpc":false,"tari_synced":false,"tari_height":0}')
        bad "approved endpoints landed but current p2pool never proved the Tari chain_id round trip (provider=${CI_NODE_PROVIDER:-unknown} runtime=$REMOTE_NODE_RUNTIME_REASON readiness=$readiness; mm log: $(mm_roundtrip_verdict "$logs"))"
        node_ok=0
    fi
    [ "$node_ok" -eq 1 ] || return 1
}

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

_node_readiness_self_test() (
    _ssh() {
        [ "$SSH_TIMEOUT" = 15 ] || return 1
        case "$1" in *'PROBE_MONERO_URL=http://node.fixture:18081'*'MoneroClient(url=os.environ["PROBE_MONERO_URL"])'*) ;; *) return 1 ;; esac
        printf '%s' '{"monero_rpc":true,"monero_synced":true,"monero_height":7,"tari_rpc":false,"tari_synced":false,"tari_height":8,"host":"private","password":"secret"}'
    }
    [ "$(guest_node_readiness node.fixture 18081)" = '{"monero_rpc":true,"monero_synced":true,"monero_height":7,"tari_rpc":false,"tari_synced":false,"tari_height":8}' ]
)

_remote_node_runtime_reason_self_test() (
    local snapshot='PITHEAD_P2POOL_STARTED=epoch-one'
    _ssh() { return 1; }
    remote_node_runtime_verdict monero.fixture 18081 18083 tari.fixture 18142 "$snapshot" && return 1
    [ "$REMOTE_NODE_RUNTIME_REASON" = container-epoch-unreadable ] || return 1
    remote_node_runtime_verdict monero.fixture 18081 18083 tari.fixture 18142 invalid && return 1
    [ "$REMOTE_NODE_RUNTIME_REASON" = startup-epoch-missing ]
)

# Drives the real verdict through a guest-shaped shell: a fake `podman` printing podman-shaped
# inspect JSON (.Name without Docker's leading slash) and a fixture config in place of the guest's.
_local_node_login_self_test() (
    local tmp login
    tmp=$(mktemp -d) || return 1
    trap 'rm -rf "$tmp"' EXIT
    printf '{"monero":{"node_username":"u1","node_password":"p1"}}' >"$tmp/config.json"
    login=u1:p1
    _ssh() { PATH="$tmp:$PATH" bash -c "${1//\/data\/pithead\/config.json/$tmp/config.json}"; }
    write_podman() {
        printf '#!/bin/sh\ncat <<EOF\n[{"Name":"monerod","Config":{"Env":["MONERO_NODE_USERNAME=u1","MONERO_NODE_PASSWORD=p1"],"Cmd":[]}},{"Name":"dashboard","Config":{"Env":["MONERO_NODE_USERNAME=u1","MONERO_NODE_PASSWORD=p1"],"Cmd":[]}},{"Name":"p2pool","Config":{"Env":[],"Cmd":["--rpc-login","%s"]}}]\nEOF\n' "$1" >"$tmp/podman"
        chmod +x "$tmp/podman"
    }
    write_podman "$login"
    local_node_login_runtime_verdict || return 1
    write_podman u1:stale
    ! local_node_login_runtime_verdict
)

# podman's `logs --since` gets StartedAt as RFC 3339; the raw form stays the restart epoch.
_startup_since_self_test() (
    local out
    _ssh() {
        case "$1" in
        *'podman inspect'*) printf '2026-09-24 22:06:05.123456789 +0000 UTC\n' ;;
        *"podman logs --since '2026-09-24T22:06:05.123456789+00:00' p2pool"*) printf 'MergeMiningClientTari ok\n' ;;
        esac
    }
    out=$(p2pool_current_startup_merge_lines)
    [ "$out" = $'PITHEAD_P2POOL_STARTED=2026-09-24 22:06:05.123456789 +0000 UTC\nMergeMiningClientTari ok' ]
)

# The proposal changes only monero.* and tari.* against the config live at preview (default-deny
# refused p2pool.clearnet, job 1044); an early failure still restores the snapshot.
_reserved_node_proposal_scope_self_test() (
    local out clearnet=false restored=0
    PITHEAD_OS_MONERO_NODE_HOST=mh PITHEAD_OS_MONERO_RPC_PORT=1 PITHEAD_OS_MONERO_ZMQ_PORT=2
    PITHEAD_OS_TARI_NODE_HOST=th PITHEAD_OS_TARI_GRPC_PORT=3
    PITHEAD_OS_MONERO_NODE_USERNAME="" PITHEAD_OS_MONERO_NODE_PASSWORD=""
    sensitive_live_config() { [ -n "${DASH_USER:-}" ] && printf '{"p2pool":{"clearnet":%s},"monero":{"mode":"local"},"tari":{"mode":"local"}}' "$clearnet"; }
    approval_capture_restore_snapshot() { APPROVAL_RESTORE_SNAPSHOT=snap; }
    approval_restore_pending() { restored=1; }
    local_node_login_edit() { return 0; }
    dashboard_config_body() { printf '%s' "$1" | jq -c '{config:.}'; }
    reserved_node_clearnet_fixture() { clearnet=true; }
    sensitive_preview() {
        printf '%s' "$1" | jq -e --argjson live "$(sensitive_live_config)" \
            '.config | del(.monero, .tari) == ($live | del(.monero, .tari))' >/dev/null && out=scoped
        return 1
    }
    ok() { :; }
    bad() { :; }
    phase_provision_remote_node_regressions fixture-user fixture-pass
    [ "${out:-}" = scoped ] && [ "$restored" -eq 1 ]
)

_remote_node_self_test() {
    local f=0 here
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    mm_roundtrip_verdict 'MergeMiningClientTari tari://127.0.0.1:18142 uses chain_id 0123456789abcdef' >/dev/null || f=$((f + 1))
    mm_roundtrip_verdict 'MergeMiningClientTari worker thread ready' >/dev/null && f=$((f + 1))
    tari_endpoint_roundtrip_verdict 'MergeMiningClientTari tari://node.fixture:18142 uses chain_id 0123456789abcdef' 'node.fixture:18142' || f=$((f + 1))
    tari_endpoint_roundtrip_verdict 'MergeMiningClientTari tari://old.fixture:18142 uses chain_id 0123456789abcdef' 'node.fixture:18142' && f=$((f + 1))
    _runtime_epoch_self_test || f=$((f + 1))
    _remote_node_proposal_self_test || f=$((f + 1))
    _node_readiness_self_test || f=$((f + 1))
    _remote_node_runtime_reason_self_test || f=$((f + 1))
    _local_node_login_self_test || f=$((f + 1))
    _reserved_node_proposal_scope_self_test || f=$((f + 1))
    _startup_since_self_test || f=$((f + 1))
    grep -Fq 'if [ "$tries" -lt 60 ]; then' "$here/appliance-node-runtime-leg.sh" || f=$((f + 1))
    [ "$f" -eq 0 ] || {
        printf 'appliance-node-runtime-leg self-test FAILED: %s checks\n' "$f"
        return 1
    }
    printf 'appliance-node-runtime-leg self-test passed\n'
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --self-test ]; then
    set -uo pipefail
    # shellcheck source=tests/os/appliance-approval-verdict.sh
    . "$(cd "$(dirname "$0")" && pwd)/appliance-approval-verdict.sh"
    # shellcheck source=tests/integration/lib/mergemine-probe.sh
    . "$(cd "$(dirname "$0")/../integration/lib" && pwd)/mergemine-probe.sh"
    _remote_node_self_test
fi
