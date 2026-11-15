#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/rig-adopt-leg.sh
source "${RIG_ADOPT_LEG_SOURCE:-$HERE/rig-adopt-leg.sh}"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
ok() { printf '%s\n' "$*"; }
bad() { printf '%s\n' "$*"; }
info() { printf '%s\n' "$*"; }
sleep() { :; }
date() {
    local tick
    tick=$(cat "$scratch/tick")
    printf '%s\n' "$((tick + 10))" >"$scratch/tick"
    printf '%s\n' "$tick"
}
_control_requests_drained() { [ "$scenario" != undrained ]; }
provisioning_settled() { [ "$scenario" != provisioning-busy ]; }
provisioning_setup_failed() { [ "$scenario" = provisioning-failed ]; }
_rig_share_state() {
    local adopted=false api=true
    if [ -f "$scratch/adopted" ]; then
        adopted=true
        [ "$scenario" != api-down ] || api=false
        [ "$scenario" != stale-adoption ] || adopted=false
    fi
    case "$scenario" in
    already-adopted) adopted=true ;;
    malformed-state)
        printf '{'
        return 0
        ;;
    missing-worker)
        printf '{"workers":[]}'
        return 0
        ;;
    unavailable-state) return 1 ;;
    esac
    jq -nc --argjson adopted "$adopted" --argjson api "$api" \
        '{workers:[{name:"kvm-rig-share",adopted:$adopted,api_ok:$api}]}'
}
_ssh() {
    case "$*" in
    *dashboard.control.enabled*)
        [ "$ip" = "$coord_ip" ] || fail 'enabled control on the rig'
        [ "$scenario" != enable-fails ] || return 1
        touch "$scratch/enabled"
        ;;
    *DONATION*)
        [ "$ip" = "$rig_ip" ] || fail 'read donation from the coordinator'
        [ "$scenario" != missing-original ] || return 1
        cat "$scratch/donation"
        ;;
    *sha256sum*)
        [ "$ip" = "$rig_ip" ] || fail 'read pools from the coordinator'
        printf '%s  -\n' "$(cat "$scratch/pools")"
        ;;
    *) fail 'unexpected SSH command' ;;
    esac
}
dashboard_curl() {
    [ "$ip" = "$coord_ip" ] || fail 'config request targeted the rig'
    [ -f "$scratch/enabled" ] || fail 'config requested before control enabled'
    case "$*" in
    '-fsSk -m 10 https://192.0.2.2/api/worker?name=kvm-rig-share')
        [ "$scenario" != missing-effective ] || return 1
        local value id="" row=accepted polls=0
        value=$(cat "$scratch/donation")
        [ "$value" != unset ] || value=1
        if [ -f "$scratch/change-id" ]; then
            id=$(cat "$scratch/change-id")
            polls=$(cat "$scratch/history-polls")
            printf '%s\n' "$((polls + 1))" >"$scratch/history-polls"
            [ "$polls" -lt 2 ] || row=applied
            case "$scenario" in
            history-stuck) row=accepted ;;
            history-rejected) row=rejected ;;
            history-wrong-id) id=ffffffffffffffff ;;
            history-unavailable) return 1 ;;
            history-malformed)
                printf '{'
                return 0
                ;;
            history-secret-status) row="$card_token" ;;
            esac
        fi
        jq -nc --argjson value "$value" --arg id "$id" --arg row "$row" \
            '{rig_config:{DONATION:$value},history: ([{change_id:"eeeeeeeeeeeeeeee",status:"applied"}] +
                (if $id == "" then [] else [{change_id:$id,status:$row}] end))}'
        ;;
    '-fsSk -m 10 https://192.0.2.2/api/config') printf '{"workers":{"list":[{"name":"existing","token":{"__secret__":true}}]}}' ;;
    *) fail 'unexpected dashboard URL' ;;
    esac
}
dashboard_control_request() {
    [ "$ip" = "$coord_ip" ] || fail 'control request targeted the rig'
    [ "$DASH_USER:$DASH_PASS" = 'fixture:login' ] || fail 'coordinator login missing'
    printf '%s\n' "$1" >>"$scratch/requests"
    case "$1" in
    preview)
        printf '%s' "$2" | jq -e --arg token "$card_token" --arg host "$rig_ip" '
            .config.workers.list | length == 2 and .[0].name == "existing" and
            .[0].token.__secret__ == true and .[1] ==
            {name:"kvm-rig-share",host:$host,port:8081,control_port:8082,token:$token}' >/dev/null ||
            fail 'proposal does not preserve and append descriptors'
        [ "$scenario" != preview-fails ] || return 1
        printf '{"id":"fixture-intent","status":"previewed"}'
        ;;
    commit)
        printf '%s' "$2" | jq -e '.id == "fixture-intent" and .confirm == "APPLY"' >/dev/null || fail 'commit lacks typed APPLY'
        [ "$scenario" != commit-fails ] || return 1
        touch "$scratch/adopted"
        printf '{"status":"applied"}'
        ;;
    worker-apply)
        local value
        value=$(printf '%s' "$2" | jq -er 'select(.worker == "kvm-rig-share") | .changes.DONATION') || fail 'wrong worker change'
        printf '%s\n' "$value" >>"$scratch/writes"
        if [ "$value" = "$original_value" ]; then
            [ "$scenario" != restore-fails ] || return 1
        else
            [ "$scenario" != write-fails ] || return 1
            [ "$scenario" != changed-pools ] || printf 'changed\n' >"$scratch/pools"
        fi
        if [ "$scenario" != false-applied ]; then printf '%s\n' "$value" >"$scratch/donation"; fi
        local id=0000000000000001
        [ "$value" != "$original_value" ] || id=0000000000000002
        printf '%s\n' "$id" >"$scratch/change-id"
        printf '0\n' >"$scratch/history-polls"
        if [ "$scenario" = malformed-change-id ]; then id=invalid; fi
        printf '{"status":"accepted","change_id":"%s"}' "$id"
        ;;
    *) fail 'unexpected control route' ;;
    esac
}
curl() {
    [ "$*" = "-sS -m 5 -o /dev/null -w %{http_code} http://$rig_ip:8082/status" ] || fail 'wrong unpinned probe'
    if [ "$scenario" = exposed-port ]; then printf 401; else
        printf 000
        return 7
    fi
}
run_case() {
    local scenario="$1" expected="$2" original_value="${3:-5}" rc=0
    local rig_ip=192.0.2.1 coord_ip=192.0.2.2 ip=192.0.2.1 coord_user=fixture coord_pass=login
    local card_token=fixture-card-secret rig_card='{"token":"fixture-card-secret"}'
    local stored_value="$original_value"
    case "$scenario" in absent-original | missing-effective) stored_value=unset original_value=1 ;; esac
    rm -f "$scratch/adopted" "$scratch/enabled" "$scratch/writes" "$scratch/change-id" "$scratch/history-polls"
    printf '0\n' >"$scratch/tick"
    printf '%s\n' "$stored_value" >"$scratch/donation"
    printf 'original\n' >"$scratch/pools"
    : >"$scratch/requests"
    rig_adopt_leg >"$scratch/output" 2>&1 || rc=$?
    [ "$rc" = "$expected" ] || fail "$scenario returned $rc, expected $expected"
    ! grep -Fq "$card_token" "$scratch/output" || fail "$scenario disclosed the card token"
    [ "$ip" = "$rig_ip" ] || fail "$scenario changed caller guest"
    if [ "$expected" = 0 ]; then
        [ "$(cat "$scratch/donation")" = "$original_value" ] || fail 'donation was not restored'
        [ "$(cat "$scratch/pools")" = original ] || fail 'pools were changed'
        [ "$(wc -l <"$scratch/writes")" -eq 2 ] || fail 'missing write or restore'
        [ "$(cat "$scratch/history-polls")" -ge 3 ] || fail 'accepted response bypassed history completion'
        grep -q 'added .* seconds' "$scratch/output" || fail 'missing elapsed time'
    fi
    case "$scenario" in
    write-fails | false-applied | changed-pools | restore-fails)
        [ "$(tail -1 "$scratch/writes")" = "$original_value" ] || fail "$scenario did not attempt restore"
        ;;
    esac
    printf 'PASS: %s\n' "$scenario"
}
run_case success 0
run_case zero-original 0 0
run_case absent-original 0
for scenario in already-adopted malformed-state missing-worker unavailable-state missing-original undrained provisioning-busy provisioning-failed \
    enable-fails preview-fails commit-fails stale-adoption api-down missing-effective write-fails false-applied changed-pools restore-fails exposed-port \
    history-stuck history-rejected history-wrong-id history-unavailable history-malformed history-secret-status malformed-change-id; do
    run_case "$scenario" 1
done
(
    # shellcheck source=tests/os/provision-browser-submit.sh
    source "$HERE/provision-browser-submit.sh"
    control_request_evidence() { :; }
    control_request_guest_evidence() { fail 'worker acknowledgment waited on a permanent spool result'; }
    dashboard_control_post() {
        printf '{"id":"11111111-1111-4111-8111-111111111111","status":"%s","change_id":"0000000000000001"}\n200' "$shape"
    }
    dashboard_curl() {
        [ "$*" = '-sSk -m 8 -w \n%{http_code} https://192.0.2.2/api/control/result?id=11111111-1111-4111-8111-111111111111' ] || fail 'incorrect spool poll URL'
        printf 'poll\n' >>"$scratch/spool-polls"
        printf '{"status":"accepted","change_id":"0000000000000001"}\n200'
    }
    ip=192.0.2.2
    for shape in accepted pending; do
        printf '0\n' >"$scratch/tick"
        : >"$scratch/spool-polls"
        result=$(dashboard_control_request worker-apply '{"worker":"kvm-rig-share","changes":{"DONATION":0}}' 60) ||
            fail "$shape worker response did not hand off to history polling"
        printf '%s' "$result" | jq -e '.status == "accepted" and .change_id == "0000000000000001"' >/dev/null ||
            fail 'worker acknowledgment lost its change id'
        expected=0
        [ "$shape" != pending ] || expected=1
        [ "$(wc -l <"$scratch/spool-polls")" -eq "$expected" ] || fail 'spool polling continued after worker acceptance'
    done
)
printf 'PASS: immediate and delayed worker acknowledgment handoff\n'
(
    original=5 probe=0 pools=original
    _rig_adopt_apply() {
        if [ "$1" = "$probe" ]; then kill -TERM "$BASHPID"; else touch "$scratch/signal-restored"; fi
    }
    flags=$(_rig_adopt_round_trip) && fail 'interrupted round trip passed'
    [ "$flags" = restored ] && [ -f "$scratch/signal-restored" ] || fail 'SIGTERM skipped restoration'
)
printf 'PASS: SIGTERM restoration\n'
