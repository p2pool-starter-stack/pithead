# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2329  # fake functions and dynamic globals are the controls
# Verdicts and fake-transport failure controls for appliance-config-approval-leg.sh.

approval_prompt_verdict() { # <prompt-text> <required-text>...
    local prompt="$1" required
    shift
    [ -n "$prompt" ] || return 1
    for required in "$@"; do
        case "$prompt" in *"$required"*) ;; *) return 1 ;; esac
    done
}

approval_audit_verdict() { # <JSONL> <request-id>
    printf '%s\n' "$1" | jq -se --arg id "$2" 'any(.[];
        .id == $id and .action == "commit-approved" and .status == "applied" and .approver == "tg-1966")' >/dev/null
}

tari_endpoint_roundtrip_verdict() { # <p2pool-startup-log> <expected-host:port>
    local plain
    plain=$(printf '%s\n' "$1" | mm_strip_ansi)
    printf '%s\n' "$plain" | grep -aF "MergeMiningClientTari tari://$2 uses chain_id " | grep -aqE 'uses chain_id [0-9a-f]{16,}'
}

_control_request_transport_self_test() (
    local secret='os1966-secret-not-in-argv' body result ip=fixture transport_fail=0
    body=$(jq -nc --arg password "$secret" '{config:{monero:{node_password:$password}}}')
    dashboard_curl() {
        local arg stdin_body
        stdin_body=$(cat)
        [ "$stdin_body" = "$body" ] || return 92
        while [ "$#" -gt 0 ]; do
            arg="$1"
            case "$arg" in *"$secret"*) return 91 ;; esac
            if [ "$arg" = --data-binary ]; then
                [ "$2" = @- ] || return 93
                shift 2
            else
                shift
            fi
        done
        [ "$transport_fail" -eq 0 ] || return 94
        printf '{"id":"fixture","status":"previewed"}'
    }
    result=$(dashboard_control_request preview "$body") || return 1
    [ "$result" = '{"id":"fixture","status":"previewed"}' ] || return 1
    transport_fail=1
    dashboard_control_request preview "$body" >/dev/null 2>&1 && return 1
    return 0
)

approval_fixture_post() { # <route> <body>; unique actor lets cleanup recover an interrupted ID
    # Root's SSH reaches the app's fixed loopback directly: Caddy correctly overwrites X-Auth-User,
    # so it cannot carry the fixture identity needed to distinguish concurrent operator requests.
    # The commit still crosses the authenticated public route; only preview needs this owner tag.
    printf '%s' "$2" | _ssh "curl -fsS -m 30 -H 'Content-Type: application/json' -H 'X-Pithead-Control: 1' -H 'X-Auth-User: $APPROVAL_FIXTURE_OWNER' --data-binary @- http://127.0.0.1:8000/api/control/$1"
}

approval_fixture_preview() {
    local body="$1" deadline status
    approval_fixture_arm || return 1
    APPROVAL_PREVIEW=$(approval_fixture_post preview "$body") || {
        approval_fixture_disarm || true
        return 1
    }
    APPROVAL_REQUEST_ID=$(printf '%s' "$APPROVAL_PREVIEW" | jq -r '.id // ""')
    approval_fixture_bind "$APPROVAL_REQUEST_ID" || {
        approval_fixture_disarm || true
        return 1
    }
    deadline=$(($(date +%s) + 240))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        status=$(printf '%s' "$APPROVAL_PREVIEW" | jq -r '.status // "pending"' 2>/dev/null) || status=pending
        [ "$status" = pending ] || [ "$status" = running ] || return 0
        sleep 3
        APPROVAL_PREVIEW=$(dashboard_curl -sSk -m 8 "https://$ip/api/control/result?id=$APPROVAL_REQUEST_ID" 2>/dev/null)
    done
    approval_fixture_disarm || true
    return 1
}

_approval_fixture_failure_self_test() (
    local f=0 ip=fixture command_file command ssh_called=0
    _ssh() { ssh_called=1; }
    approval_fixture_bind not-an-id && f=$((f + 1))
    [ "$ssh_called" -eq 0 ] || f=$((f + 1))
    _ssh() { return 1; }
    APPROVAL_FIXTURE_ARMED=0
    ! approval_fixture_arm && [ "$APPROVAL_FIXTURE_ARMED" -eq 2 ] || f=$((f + 1))
    command_file=$(mktemp)
    _ssh() {
        case "$1" in
        "if test -f"*) printf absent ;;
        *) printf '%s' "$1" >"$command_file" ;;
        esac
    }
    approval_fixture_disarm && [ "$APPROVAL_FIXTURE_ARMED" -eq 0 ] || f=$((f + 1))
    command=$(cat "$command_file")
    case "$command" in *"systemctl start pithead-control.path"*) ;; *) f=$((f + 1)) ;; esac
    APPROVAL_FIXTURE_ARMED=1 APPROVAL_FIXTURE_OWNER=os1966-1-2-3
    ! approval_fixture_disarm && [ "$APPROVAL_FIXTURE_ARMED" -eq 1 ] || f=$((f + 1))
    _ssh() {
        case "$1" in
        "if test -f"*) printf '%s' "$APPROVAL_FIXTURE_OWNER" ;;
        *) printf '%s' "$1" >"$command_file" ;;
        esac
    }
    APPROVAL_FIXTURE_ARMED=1 APPROVAL_FIXTURE_OWNER=os1966-1-2-3
    approval_fixture_quiesce || f=$((f + 1))
    command=$(cat "$command_file")
    rm -f "$command_file"
    case "$command" in
    *"systemctl stop pithead-control.path"*"systemctl stop pithead-control.service"*".os1966-active-owner"*'.actor == $owner'*'requests/$id.json'*'.$id.approval-'*'.$id.telegram-'*) ;;
    *) f=$((f + 1)) ;;
    esac
    case "$command" in *"-name '*.json' -exec mv"*) f=$((f + 1)) ;; esac
    _ssh() { ssh_called=1; }
    approval_fixture_quiesce() { return 1; }
    APPROVAL_FIXTURE_ARMED=1 ssh_called=0
    ! approval_fixture_disarm && [ "$APPROVAL_FIXTURE_ARMED" -eq 1 ] && [ "$ssh_called" -eq 0 ] || f=$((f + 1))
    [ "$f" -eq 0 ]
)

_approval_owner_selector_self_test() (
    local owner=os1966-1-2-3 id=00000000-0000-4000-8000-000000000001
    printf '{"actor":"%s","id":"%s"}\n' "$owner" "$id" |
        jq -er --arg owner "$owner" 'select(.actor == $owner) | .id' | grep -qxF "$id" || return 1
    ! printf '{"actor":"operator","id":"%s"}\n' "$id" |
        jq -er --arg owner "$owner" 'select(.actor == $owner) | .id' >/dev/null
)

_approval_preview_lifecycle_self_test() (
    local order_file
    order_file=$(mktemp)
    trap 'rm -f "$order_file"' EXIT
    approval_fixture_arm() {
        APPROVAL_FIXTURE_ARMED=1
        printf 'arm ' >>"$order_file"
    }
    approval_fixture_post() {
        printf 'preview ' >>"$order_file"
        printf '{"id":"00000000-0000-4000-8000-000000000001"}'
    }
    approval_fixture_bind() {
        printf 'bind ' >>"$order_file"
        return 1
    }
    approval_fixture_disarm() {
        APPROVAL_FIXTURE_ARMED=0
        printf 'disarm ' >>"$order_file"
    }
    APPROVAL_FIXTURE_ARMED=0
    approval_fixture_preview '{}' && return 1
    [ "$APPROVAL_FIXTURE_ARMED" -eq 0 ] || return 1
    [ "$(cat "$order_file")" = "arm preview bind disarm " ]
)

_approval_fixture_cleanup_self_test() (
    local root owner=os1966-1-2-3 owned=00000000-0000-4000-8000-000000000001
    local other=00000000-0000-4000-8000-000000000002 restore_log ip=fixture
    root=$(mktemp -d)
    restore_log=$root/restore.log
    trap 'rm -rf "$root"' EXIT
    mkdir -p "$root/data/pithead/data/control/"{requests,staged,audit} \
        "$root/data/pithead/.os-approval-fixture/bin" "$root/etc/systemd/system/pithead-control.service.d" "$root/bin" "$root/state"
    cat >"$root/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
set -eu
state=${APPROVAL_SYSTEMCTL_STATE:?}
case "$1" in
stop) rm -f "$state/$2" ;;
start) : >"$state/$2" ;;
is-active) shift; [ "${1:-}" = --quiet ] && shift; test -f "$state/$1" ;;
daemon-reload) ;;
cat) printf '[Service]\nExecStart=/usr/bin/true\n' ;;
*) exit 90 ;;
esac
FAKE
    chmod 700 "$root/bin/systemctl"
    : >"$root/state/pithead-control.path"
    _ssh() {
        local command=${1//\/data\/pithead/$root\/data\/pithead}
        command=${command//\/etc\/systemd\/system/$root\/etc\/systemd\/system}
        APPROVAL_SYSTEMCTL_STATE="$root/state" PATH="$root/bin:$PATH" bash -c "$command"
    }
    approval_restore_pending() {
        printf 'restored\n' >>"$restore_log"
        APPROVAL_RESTORE_SNAPSHOT=""
    }

    # A stale active ID must prevent a new owner claim and leave its operator-owned work untouched.
    printf '%s' "$other" >"$root/data/pithead/data/control/.os1966-active-id"
    printf '{"actor":"operator","id":"%s"}\n' "$other" >"$root/data/pithead/data/control/requests/$other.json"
    printf '{}\n' >"$root/data/pithead/data/control/staged/$other.json"
    APPROVAL_FIXTURE_ARMED=0
    approval_fixture_arm && return 1
    [ "$APPROVAL_FIXTURE_ARMED" -eq 2 ] || return 1
    [ ! -e "$root/data/pithead/data/control/.os1966-active-owner" ] || return 1
    [ -f "$root/data/pithead/data/control/requests/$other.json" ] || return 1
    [ -f "$root/data/pithead/data/control/staged/$other.json" ] || return 1
    approval_fixture_disarm || return 1
    [ -f "$root/state/pithead-control.path" ] || return 1
    [ -f "$root/data/pithead/data/control/.os1966-active-id" ] || return 1
    [ -f "$root/data/pithead/data/control/requests/$other.json" ] || return 1
    [ -f "$root/data/pithead/data/control/staged/$other.json" ] || return 1

    # Normal cleanup sees the owner ID twice: a marker without a newline and the audit row.
    # It must delete only owner-evidenced artifacts, restore config, and restart the path.
    printf '%s' "$owner" >"$root/data/pithead/data/control/.os1966-active-owner"
    printf '%s' "$owned" >"$root/data/pithead/data/control/.os1966-active-id"
    printf '{"actor":"%s","id":"%s"}\n' "$owner" "$owned" >"$root/data/pithead/data/control/audit/control.log"
    printf '{}\n' >"$root/data/pithead/data/control/staged/$owned.json"
    printf '{}\n' >"$root/data/pithead/data/control/staged/.$owned.approval-pending"
    printf '{"actor":"operator","id":"%s"}\n' "$other" >"$root/data/pithead/data/control/.claim.zzz"
    printf '{}\n' >"$root/data/pithead/data/control/staged/.$other.approval-pending"
    APPROVAL_FIXTURE_ARMED=1 APPROVAL_FIXTURE_OWNER=$owner APPROVAL_RESTORE_SNAPSHOT=fixture
    approval_fixture_cleanup || return 1
    [ "$(cat "$restore_log")" = restored ] || return 1
    [ -f "$root/state/pithead-control.path" ] || return 1
    [ ! -e "$root/data/pithead/data/control/staged/$owned.json" ] || return 1
    [ ! -e "$root/data/pithead/data/control/staged/.$owned.approval-pending" ] || return 1
    [ -f "$root/data/pithead/data/control/requests/$other.json" ] || return 1
    [ -f "$root/data/pithead/data/control/staged/$other.json" ] || return 1
    [ -f "$root/data/pithead/data/control/.claim.zzz" ] || return 1
    [ -f "$root/data/pithead/data/control/staged/.$other.approval-pending" ] || return 1
    [ ! -e "$root/data/pithead/data/control/.os1966-active-owner" ] || return 1
    [ ! -e "$root/data/pithead/data/control/.os1966-active-id" ] || return 1
)

_runtime_epoch_self_test() (
    local count_file ip=fixture n
    count_file=$(mktemp)
    printf '0\n' >"$count_file"
    trap 'rm -f "$count_file"' EXIT
    _ssh() {
        case "$1" in
        *".State.StartedAt"*)
            n=$(cat "$count_file")
            n=$((n + 1))
            printf '%s\n' "$n" >"$count_file"
            [ "$n" -lt 4 ] && printf 'epoch-one\n' || printf 'epoch-two\n'
            ;;
        *"sed -n"*) printf 'MONERO_NODE_HOST=monero.fixture\nMONERO_RPC_PORT=18081\nMONERO_ZMQ_PORT=18083\nTARI_GRPC_ADDRESS=tari.fixture:18142\n' ;;
        *".Config.Cmd"*) printf 'monero.fixture\t18081\t18083\ttari://tari.fixture:18142\n' ;;
        *".Config.Env"*) return 0 ;;
        esac
    }
    local snapshot='PITHEAD_P2POOL_STARTED=epoch-one
MergeMiningClientTari tari://tari.fixture:18142 uses chain_id 0123456789abcdef'
    remote_node_runtime_verdict monero.fixture 18081 18083 tari.fixture 18142 "$snapshot" || return 1
    remote_node_runtime_verdict monero.fixture 18081 18083 tari.fixture 18142 "$snapshot" && return 1
    return 0
)
