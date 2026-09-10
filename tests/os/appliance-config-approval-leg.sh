#!/usr/bin/env bash
# Host-mediated configuration approval and remote-node consumption (#1959/#1966). Sourced by
# tests/os/run.sh; --self-test covers the pure consumer verdict without a guest or network.
# shellcheck source=tests/os/appliance-approval-verdict.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/appliance-approval-verdict.sh"

APPROVAL_FIXTURE_ARMED=0
APPROVAL_RESTORE_SNAPSHOT=""
approval_fixture_arm() {
    APPROVAL_FIXTURE_OWNER="os1966-$(date +%s)-$$-$RANDOM"
    [[ "$APPROVAL_FIXTURE_OWNER" =~ ^os1966-[0-9]+-[0-9]+-[0-9]+$ ]] || return 1
    APPROVAL_FIXTURE_ARMED=2
    _ssh "set -eu; test ! -e /data/pithead/data/control/.os1966-active-owner; test ! -e /data/pithead/data/control/.os1966-active-id; umask 077; printf '%s' '$APPROVAL_FIXTURE_OWNER' > /data/pithead/data/control/.os1966-active-owner" || return
    APPROVAL_FIXTURE_ARMED=1
    _ssh 'set -eu
rm -rf /data/pithead/.os-approval-fixture
mkdir -p /data/pithead/.os-approval-fixture/bin /etc/systemd/system/pithead-control.service.d
test -z "$(find /data/pithead/data/control/staged -maxdepth 1 -type f -name '"'"'.*.approval-pending'"'"' -print -quit)"
cat > /data/pithead/.os-approval-fixture/bin/curl <<'"'"'FAKE'"'"'
#!/usr/bin/env bash
out="" payload=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    -o) out="$2"; shift 2 ;;
    --data-binary) payload="${2#@}"; shift 2 ;;
    *) shift ;;
    esac
done
read -r api_url
case "$api_url" in
*botos1966-fake-token/sendMessage*)
    cp "$payload" /data/pithead/.os-approval-fixture/prompt.json
    printf '"'"'{"ok":true,"result":{"message_id":1966,"chat":{"id":-1001966}}}\n'"'"' >"$out"
    ;;
*botos1966-fake-token/getUpdates*)
    pending=$(find /data/pithead/data/control/staged -name '"'"'.*.approval-pending'"'"' -print -quit)
    nonce=$(jq -r '"'"'.nonce'"'"' "$pending")
    text=$(jq -er '"'"'.text | strings | select(length > 0)'"'"' /data/pithead/.os-approval-fixture/prompt.json) || exit 98
    uid=$(cat /data/pithead/.os-approval-fixture/uid 2>/dev/null || printf 1966)
    jq -n --arg nonce "$nonce" --arg text "$text" --argjson uid "$uid" '"'"'{ok:true,result:[{update_id:1,callback_query:{id:"fixture",from:{id:$uid},data:("approve-config:"+$nonce),message:{message_id:1966,chat:{id:-1001966},text:$text}}}]}'"'"' >"$out"
    ;;
*)
    printf '"'"'%s\n'"'"' "$api_url" >>/data/pithead/.os-approval-fixture/unexpected-url
    exit 97
    ;;
esac
FAKE
chmod 700 /data/pithead/.os-approval-fixture/bin/curl
cat > /etc/systemd/system/pithead-control.service.d/90-os-approval-fixture.conf <<'"'"'UNIT'"'"'
[Service]
Environment="PATH=/data/pithead/.os-approval-fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
UNIT
systemctl daemon-reload
systemctl start pithead-control.path
systemctl is-active --quiet pithead-control.path
systemctl cat pithead-control.service | grep -qxF '"'"'Environment="PATH=/data/pithead/.os-approval-fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"'"'"'
test ! -e /data/pithead/.os-approval-fixture/unexpected-url' || return
}

approval_fixture_bind() {
    local id="$1"
    [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || return 1
    _ssh "set -eu; test ! -e /data/pithead/data/control/.os1966-active-id; umask 077; printf '%s' '$id' > /data/pithead/data/control/.os1966-active-id"
}

approval_fixture_quiesce() {
    [ "${APPROVAL_FIXTURE_ARMED:-0}" -ne 0 ] || return 0
    [ -n "${ip:-}" ] || return 1
    local marker
    marker=$(_ssh 'if test -f /data/pithead/data/control/.os1966-active-owner; then cat /data/pithead/data/control/.os1966-active-owner; else printf absent; fi') || return 1
    if [ "$marker" = absent ]; then
        [ "$APPROVAL_FIXTURE_ARMED" -eq 2 ] && return 0
        return 1
    fi
    [ "$marker" = "$APPROVAL_FIXTURE_OWNER" ] || return 1
    _ssh 'set -eu
systemctl stop pithead-control.path
systemctl stop pithead-control.service
! systemctl is-active --quiet pithead-control.service
mkdir -p /data/pithead/.os-approval-fixture/cancelled
owner=$(cat /data/pithead/data/control/.os1966-active-owner)
printf "%s" "$owner" | grep -qE '"'"'^os1966-[0-9]+-[0-9]+-[0-9]+$'"'"'
ids=/data/pithead/.os-approval-fixture/owned.ids
: >"$ids"
for f in /data/pithead/data/control/requests/*.json /data/pithead/data/control/.claim.*; do
    [ -f "$f" ] || continue
    jq -e . "$f" >/dev/null 2>&1
    jq -r --arg owner "$owner" '"'"'select(.actor == $owner) | .id | select(test("^[0-9a-f-]{36}$"))'"'"' "$f" >>"$ids"
done
[ ! -f /data/pithead/data/control/audit/control.log ] || jq -r --arg owner "$owner" '"'"'select(.actor == $owner) | .id // empty'"'"' /data/pithead/data/control/audit/control.log >>"$ids"
if [ -f /data/pithead/data/control/.os1966-active-id ]; then
    active=$(cat /data/pithead/data/control/.os1966-active-id)
    if grep -qxF "$active" "$ids"; then printf "%s\n" "$active" >>"$ids"; fi
fi
sort -u "$ids" -o "$ids"
while IFS= read -r id; do
    printf "%s" "$id" | grep -qE '"'"'^[0-9a-f-]{36}$'"'"' || continue
    for f in /data/pithead/data/control/requests/$id.json /data/pithead/data/control/staged/$id.json* /data/pithead/data/control/staged/.$id.approval-* /data/pithead/data/control/staged/.$id.telegram-*; do
        [ -f "$f" ] && mv -- "$f" /data/pithead/.os-approval-fixture/cancelled/
    done
done <"$ids"
for f in /data/pithead/data/control/.claim.*; do
    [ -f "$f" ] || continue
    if jq -e --arg owner "$owner" '"'"'.actor == $owner'"'"' "$f" >/dev/null 2>&1; then
        mv -- "$f" /data/pithead/.os-approval-fixture/cancelled/
    fi
done'
}

approval_fixture_disarm() {
    local rc=0
    approval_fixture_quiesce || return 1
    [ "${APPROVAL_FIXTURE_ARMED:-0}" -ne 0 ] || return "$rc"
    _ssh "set -eu
owned=0
if test -f /data/pithead/data/control/.os1966-active-owner; then
    grep -qxF '$APPROVAL_FIXTURE_OWNER' /data/pithead/data/control/.os1966-active-owner
    owned=1
"'
    rm -rf /data/pithead/.os-approval-fixture /etc/systemd/system/pithead-control.service.d/90-os-approval-fixture.conf
    rm -f /data/pithead/data/control/.os1966-active-id /data/pithead/data/control/.os1966-active-owner
fi
    systemctl daemon-reload
    systemctl start pithead-control.path
    systemctl is-active --quiet pithead-control.path
    if test "$owned" = 1; then
        test ! -e /data/pithead/.os-approval-fixture
        test ! -e /etc/systemd/system/pithead-control.service.d/90-os-approval-fixture.conf
        ! systemctl cat pithead-control.service | grep -q /data/pithead/.os-approval-fixture
    fi' >/dev/null 2>&1 || rc=1
    [ "$rc" -eq 0 ] && APPROVAL_FIXTURE_ARMED=0
    return "$rc"
}

approval_fixture_require_disarm() {
    approval_fixture_disarm || {
        bad "isolated Telegram approval fixture could not be removed"
        return 1
    }
}
dashboard_control_post() { # <route> <json-body>; keeps secrets out of curl's argv
    printf '%s' "$2" | dashboard_curl -sSk -m 8 -H 'Content-Type: application/json' \
        -H 'X-Pithead-Control: 1' --data-binary @- "https://$ip/api/control/$1" 2>/dev/null
}
dashboard_config_body() { printf '%s' "$1" | jq -c '{config:.}'; }

remote_node_proposal() { # <config> <monero-host> <rpc> <zmq> <user> <password> <tari-host> <grpc>
    printf '%s\0' "$@" | jq -Rsc 'split("\u0000") as $v | ($v[0] | fromjson) |
        .monero.mode="remote" | .monero.remote={host:$v[1],rpc_port:($v[2]|tonumber),zmq_port:($v[3]|tonumber)} |
        .monero.node_username=$v[4] | .monero.node_password=$v[5] |
        .tari.mode="remote" | .tari.remote={host:$v[6],grpc_port:($v[7]|tonumber)}'
}

approval_commit() { # <preview-id>; prints result, leaves prompt available until disarm
    local id="$1"
    dashboard_control_request commit "$(jq -nc --arg id "$id" '{id:$id,confirm:"APPLY",approve:true,payout_suffixes:{}}')" 420
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
    local rc=0
    approval_fixture_quiesce || rc=1
    [ "$rc" -eq 0 ] && approval_restore_pending || {
        printf '  approval cleanup FAILED to restore the original node configuration\n' >&2
        rc=1
    }
    approval_fixture_disarm || {
        printf '  approval cleanup FAILED to remove the fake provider transport\n' >&2
        rc=1
    }
    return "$rc"
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

phase_provision_sensitive_regressions() { # <dashboard-user> <dashboard-password>
    local DASH_USER="$1" DASH_PASS="$2" live proposed preview result rid before after prompt audit
    local mh="${PITHEAD_OS_MONERO_NODE_HOST:-}" rpc="${PITHEAD_OS_MONERO_RPC_PORT:-}" zmq="${PITHEAD_OS_MONERO_ZMQ_PORT:-}"
    local mu="${PITHEAD_OS_MONERO_NODE_USERNAME:-}" mp="${PITHEAD_OS_MONERO_NODE_PASSWORD:-}"
    local th="${PITHEAD_OS_TARI_NODE_HOST:-}" grpc="${PITHEAD_OS_TARI_GRPC_PORT:-}" logs tries node_ok

    live=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null) || {
        bad "sensitive config: live config could not be read"
        return
    }
    before=$(hostname_runtime_snapshot fixture-box)
    proposed=$(printf '%s' "$live" | jq -c '.dashboard.host = "fixture-next"')
    approval_fixture_preview "$(dashboard_config_body "$proposed")" || return
    preview=$APPROVAL_PREVIEW rid=$APPROVAL_REQUEST_ID
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id,confirm:"APPLY"}')")
    approval_fixture_require_disarm || return
    after=$(hostname_runtime_snapshot fixture-box)
    if printf '%s' "$result" | jq -e '.status == "rejected" and (.error | contains("Telegram approval"))' >/dev/null && [ "$before" = "$after" ]; then
        ok "day-two hostname commit is refused without host-mediated approval and leaves identity unchanged"
    else
        bad "day-two hostname crossed the second-identity gate or changed during refusal"
        return
    fi

    approval_fixture_preview "$(dashboard_config_body "$proposed")" || return
    preview=$APPROVAL_PREVIEW rid=$APPROVAL_REQUEST_ID
    _ssh 'printf 999 > /data/pithead/.os-approval-fixture/uid' || {
        bad "could not set the wrong-identity approval control"
        approval_fixture_require_disarm
        return
    }
    result=$(approval_commit "$rid")
    approval_fixture_require_disarm || return
    after=$(hostname_runtime_snapshot fixture-box)
    if printf '%s' "$result" | jq -e '.status == "rejected" and (.error | contains("allow-listed operator"))' >/dev/null && [ "$before" = "$after" ]; then
        ok "day-two hostname refuses a callback from the wrong Telegram identity"
    else
        bad "a wrong Telegram identity approved the hostname or changed it during refusal"
        return
    fi

    approval_fixture_preview "$(dashboard_config_body "$proposed")" || {
        bad "could not arm the isolated Telegram approval fixture"
        return
    }
    preview=$APPROVAL_PREVIEW rid=$APPROVAL_REQUEST_ID
    result=$(approval_commit "$rid")
    prompt=$(_ssh 'cat /data/pithead/.os-approval-fixture/prompt.json 2>/dev/null' | jq -r '.text // ""' 2>/dev/null)
    approval_fixture_require_disarm || return
    audit=$(_ssh "tail -n 20 /data/pithead/data/control/audit/control.log" 2>/dev/null)
    if printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null &&
        approval_prompt_verdict "$prompt" "HOST_IP" "fixture-box" "fixture-next" &&
        approval_audit_verdict "$audit" "$rid" &&
        assert_appliance_hostname_identity fixture-next "approved day-two hostname" "$DASH_USER" "$DASH_PASS"; then
        ok "host-generated preview and allow-listed callback bind the approved hostname commit"
    else
        bad "host-mediated hostname approval did not bind prompt, approver, apply and live identity"
        return
    fi

    live=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null) || return
    proposed=$(printf '%s' "$live" | jq -c '.dashboard.auth.password = "os1966-physical-only"')
    approval_fixture_preview "$(dashboard_config_body "$proposed")" || return
    preview=$APPROVAL_PREVIEW rid=$APPROVAL_REQUEST_ID
    result=$(approval_commit "$rid")
    approval_fixture_require_disarm || return
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
    live=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null) || return
    proposed=$(remote_node_proposal "$live" "$mh" "$rpc" "$zmq" "$mu" "$mp" "$th" "$grpc") || {
        bad "reserved-node proposal could not be constructed"
        return
    }
    approval_fixture_preview "$(dashboard_config_body "$proposed")" || return
    preview=$APPROVAL_PREVIEW
    if ! printf '%s' "$preview" | jq -e --arg mh "$mh" --arg th "$th" '
        .status == "previewed" and .destructive == true and .approval_required == true and
        any(.preview_values[]; .key == "monero.remote.host" and .new == $mh) and
        any(.preview_values[]; .key == "tari.remote.host" and .new == $th)' >/dev/null; then
        bad "reserved-node preview did not expose endpoints behind the combined approval gate"
        approval_fixture_require_disarm
        return
    fi
    rid=$APPROVAL_REQUEST_ID
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id,approve:true,payout_suffixes:{}}')")
    approval_fixture_require_disarm || return
    if printf '%s' "$result" | jq -e '.status == "rejected" and (.error | contains("type APPLY"))' >/dev/null; then
        ok "reachable-node commit is refused before probing or approval without typed APPLY"
    else
        bad "reachable-node commit crossed the typed confirmation gate"
        return
    fi
    approval_fixture_preview "$(dashboard_config_body "$proposed")" || return
    preview=$APPROVAL_PREVIEW rid=$APPROVAL_REQUEST_ID
    approval_capture_restore_snapshot || {
        bad "could not preserve the original raw configuration for guaranteed restore"
        approval_fixture_require_disarm
        return
    }
    result=$(approval_commit "$rid")
    prompt=$(_ssh 'cat /data/pithead/.os-approval-fixture/prompt.json 2>/dev/null' | jq -r '.text // ""' 2>/dev/null)
    approval_fixture_require_disarm || return
    if ! printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null; then
        bad "host preflight or host-mediated approval refused the reserved nodes"
        return
    fi
    node_ok=1
    audit=$(_ssh "tail -n 20 /data/pithead/data/control/audit/control.log" 2>/dev/null)
    approval_audit_verdict "$audit" "$rid" || {
        bad "reserved-node approval audit did not bind the current request, applied status and approver"
        node_ok=0
    }
    approval_prompt_verdict "$prompt" "$mh" "$th" || {
        bad "host-generated approval prompt omitted a reserved node endpoint"
        node_ok=0
    }
    if { [ -n "$mu" ] && case "$prompt" in *"$mu"*) true ;; *) false ;; esac } ||
        { [ -n "$mp" ] && case "$prompt" in *"$mp"*) true ;; *) false ;; esac } then
        bad "host-generated approval prompt exposed a reserved Monero credential"
        node_ok=0
    else
        ok "host-generated approval prompt exposes node endpoints without node credentials"
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
    local f=0 prompt='Approve configuration\nHOST_IP: Dashboard hostname: fixture-box → fixture-next\nTari node host: tari.fixture'
    approval_prompt_verdict "$prompt" HOST_IP fixture-box fixture-next || f=$((f + 1))
    approval_prompt_verdict "$prompt" HOST_IP missing && f=$((f + 1))
    approval_audit_verdict '{"id":"now","action":"commit-approved","status":"applied","approver":"tg-1966"}' now || f=$((f + 1))
    approval_audit_verdict '{"id":"old","action":"commit-approved","status":"applied","approver":"tg-1966"}' now && f=$((f + 1))
    mm_roundtrip_verdict 'MergeMiningClientTari tari://127.0.0.1:18142 uses chain_id 0123456789abcdef' >/dev/null || f=$((f + 1))
    mm_roundtrip_verdict 'MergeMiningClientTari worker thread ready' >/dev/null && f=$((f + 1))
    tari_endpoint_roundtrip_verdict 'MergeMiningClientTari tari://node.fixture:18142 uses chain_id 0123456789abcdef' 'node.fixture:18142' || f=$((f + 1))
    tari_endpoint_roundtrip_verdict 'MergeMiningClientTari tari://old.fixture:18142 uses chain_id 0123456789abcdef' 'node.fixture:18142' && f=$((f + 1))
    _control_request_transport_self_test || f=$((f + 1))
    _approval_fixture_failure_self_test || f=$((f + 1))
    _approval_owner_selector_self_test || f=$((f + 1))
    _approval_preview_lifecycle_self_test || f=$((f + 1))
    _approval_fixture_cleanup_self_test || f=$((f + 1))
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
