profile_default() {
    config_defaults_json | jq -c --arg path "$1" --argjson fallback "$2" --slurpfile cfg "$3" '
        .profiles[$cfg[0].profile // "balance"] as $profile
        | if $profile | has($path) then $profile[$path] else $fallback end'
}

profile_name() {
    config_get .profile "${1:-$CONFIG_FILE}"
}

profile_customized() {
    config_defaults_json | jq -e --slurpfile cfg "${1:-$CONFIG_FILE}" '
        .profiles[$cfg[0].profile // "balance"] | to_entries | any(.[];
            . as $entry | ($cfg[0] | getpath($entry.key | split("."))) as $value
            | $value != null and $value != $entry.value)' >/dev/null
}

profile_select() {
    local config="$1" target="$2" tmp
    tmp=$(mktemp) || return 1
    if config_defaults_json | jq --arg target "$target" --slurpfile cfg "$config" '
        .profiles[$target] as $values
        | if $values == null then error("unknown profile") else
            reduce ($values | keys[]) as $path ($cfg[0]; delpaths([$path | split(".")]))
            | .profile = $target end' >"$tmp" && cat "$tmp" >"$config"; then
        rm -f "$tmp"
    else
        rm -f "$tmp"
        return 1
    fi
}

profile_status() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "Profile: unavailable (configuration missing)."
        return 0
    fi
    local name
    name=$(profile_name)
    if profile_customized; then
        log "Profile: Custom ($name)"
    else
        log "Profile: $name"
    fi
    if [ "$(config_bool '.tor.auto_heal' false)" = true ] && [ "$(config_bool '.dashboard.control.enabled' false)" != true ]; then
        log "Tor auto-heal is inactive: dashboard control is disabled."
    fi
}

describe_profile_change() {
    [ "$1" = PITHEAD_PROFILE ] || return 1
    flag=CONFIRM
    case "$3" in
    performance) msg="Performance: outbound Monero, Tari, P2Pool, XvB, alerts, release checks and price feeds leave without Tor; your IP address is visible. The egress firewall is off." ;;
    balance) msg="Balance: outbound traffic uses Tor; rigs need no password by default." ;;
    privacy) msg="Privacy: P2Pool peers only over onion connections; rigs need a password and worker API token, with optional TLS. Update every rig to match." ;;
    esac
    msg+=" Profile selection clears Advanced overrides for Monero and Tari clearnet sync, P2Pool clearnet peering, egress firewall, XvB Tor, notification Tor, Tor auto-heal, rig password, rig TLS, worker API authentication and worker API token. Other explicit overrides still apply."
}
