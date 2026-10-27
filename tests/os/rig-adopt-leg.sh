# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034

_rig_adopt_state() {
    local wanted="$1" state deadline=$(($(date +%s) + 120))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if state=$(_rig_share_state) && printf '%s' "$state" | jq -e --argjson wanted "$wanted" '
            [.workers[] | select(.name == "kvm-rig-share")] |
            length == 1 and .[0].adopted == $wanted and
            (if $wanted then .[0].api_ok == true else true end)' >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
    done
    return 1
}

_rig_adopt_snapshot() {
    local donation pools ip="${rig_address:-$ip}"
    donation=$(_ssh "jq -er 'if has(\"DONATION\") then .DONATION | select(type == \"number\" and . >= 0 and . <= 100) else \"unset\" end' /data/rigforge/config.json") || return 1
    pools=$(_ssh "set -o pipefail; jq -ceS '.pools | select(type == \"array\" and length > 0)' /data/rigforge/config.json | sha256sum") || return 1
    printf '%s %s\n' "$donation" "${pools%% *}"
}

_rig_adopt_apply() {
    local value="$1" pools="$2" result snapshot deadline
    result=$(dashboard_control_request worker-apply "$(jq -nc --argjson value "$value" \
        '{worker:"kvm-rig-share",changes:{DONATION:$value}}')" 240) || return 1
    [ "$(printf '%s' "$result" | jq -r '.status // empty')" = applied ] || return 1
    deadline=$(($(date +%s) + 60))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        snapshot=$(_rig_adopt_snapshot) || snapshot=""
        [ "$snapshot" = "$value $pools" ] && return 0
        sleep 3
    done
    return 1
}

_rig_adopt_round_trip() (
    trap '_rig_adopt_apply "$original" "$pools" && printf "restored\n" || { printf "restore-failed\n"; exit 1; }' EXIT
    trap 'exit 1' INT TERM
    _rig_adopt_apply "$probe" "$pools" || exit 1
    printf 'changed\n'
)

rig_adopt_leg() {
    local started result proposed rid baseline original pools probe flags trip_rc=0 changed=0 restored=0
    started=$(date +%s)
    local DASH_USER="$coord_user" DASH_PASS="$coord_pass"
    local rig_address="$ip"
    _rig_adopt_state false || {
        bad "M12: the coordinator does not show exactly one unadopted rig (#3069)"
        return 1
    }
    ok "M12: the coordinator shows the rig as not adopted (#3069)"
    baseline=$(_rig_adopt_snapshot) || {
        bad "M12: original donation and pools could not be recorded (#3069)"
        return 1
    }
    read -r original pools <<<"$baseline"
    {
        local ip="$coord_ip"
        provisioning_settled 900 && ! provisioning_setup_failed && _control_requests_drained && _ssh 'set -eu
cd /data/pithead
umask 077
staging=$(mktemp config.json.os3069.XXXXXX)
jq ".dashboard.control.enabled = true" config.json > "$staging"
mv "$staging" config.json
./pithead apply -y >/dev/null 2>&1' || {
            bad "M12: coordinator control channel could not be enabled (#3069)"
            return 1
        }
        _rig_adopt_state false || return 1
        proposed=$(dashboard_curl -fsSk -m 10 "https://$ip/api/config" 2>/dev/null) || return 1
        proposed=$(printf '%s\n%s\n' "$proposed" "$rig_card" | jq -sce --arg host "$rig_address" '
            .[0] as $config | .[1] as $card |
            select($card.token | type == "string" and length > 0) |
            $config | .workers.list = ((.workers.list // []) +
                [{name:"kvm-rig-share",host:$host,port:8081,control_port:8082,token:$card.token}]) |
            {config:.}') || return 1
        result=$(dashboard_control_request preview "$proposed") || return 1
        [ "$(printf '%s' "$result" | jq -r '.status // empty')" = previewed ] || return 1
        rid=$(printf '%s' "$result" | jq -er '.id | select(type == "string" and length > 0)') || return 1
        result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id,confirm:"APPLY"}')" 420) || return 1
        [ "$(printf '%s' "$result" | jq -r '.status // empty')" = applied ] || return 1
    }
    _rig_adopt_state true || {
        bad "M12: adoption did not produce an adopted rig with a reachable API (#3069)"
        return 1
    }
    ok "M12: preview and typed APPLY adopt the rig with its API reachable (#3069)"
    local ip="$coord_ip"
    if [ "$original" = unset ]; then
        result=$(dashboard_curl -fsSk -m 10 "https://$ip/api/worker?name=kvm-rig-share" 2>/dev/null) &&
            original=$(printf '%s' "$result" | jq -er '.rig_config.DONATION | select(type == "number" and . >= 0 and . <= 100)') || {
            bad "M12: the rig did not report its effective DONATION default (#3069)"
            return 1
        }
    fi
    probe=$(jq -nr --argjson value "$original" 'if $value > 0 then 0 else 1 end') || return 1
    flags=$(_rig_adopt_round_trip) || trip_rc=$?
    case "$flags" in *changed*) changed=1 ;; esac
    case "$flags" in *restored*) restored=1 ;; esac
    ip="$rig_address"
    [ "$changed" = 1 ] && ok "M12: coordinator DONATION write applied on the rig with unchanged pools (#3069)" ||
        bad "M12: coordinator DONATION write or unchanged pools assertion failed (#3069)"
    [ "$restored" = 1 ] && ok "M12: original DONATION restored with unchanged pools (#3069)" ||
        bad "M12: original DONATION restoration failed (#3069)"
    local code
    code=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://$rig_address:8082/status" 2>/dev/null) || true
    if [ "$code" != 000 ]; then
        bad "M12: the rig control port answered the unpinned bench host (#3069)"
        return 1
    fi
    ok "M12: rig control port remains unreachable from the unpinned bench host (#3069)"
    info "M12: adoption and reversible config push added $(($(date +%s) - started)) seconds (#3069)"
    [ "$changed" = 1 ] && [ "$restored" = 1 ] && [ "$trip_rc" = 0 ]
}
