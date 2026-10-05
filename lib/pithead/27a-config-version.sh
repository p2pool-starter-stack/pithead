# Configuration stamps begin at 2.0.0. The host is the only writer; there are no
# version-keyed migrations until a release needs a real one.
config_code_version() {
    local version
    version=$(tr -d ' \t\r\n' <VERSION 2>/dev/null) || return 1
    version=${version%%[-+]*}
    config_version_ok "$version" || return 1
    printf '%s' "$version"
}

config_version_ok() {
    os_semver_ok "$1" && printf '%s' "$1" | grep -qE '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$'
}

stamp_config_version() {
    local stamp version owner tmp
    version=$(config_code_version) || {
        warn "Could not read the release version — config_version was not written."
        return 0
    }
    stamp=$(jq -r '.config_version // "2.0.0"' "$CONFIG_FILE")
    if config_version_ok "$stamp" && semver_newer "$stamp" "$version"; then
        warn "config.json was written by pithead $stamp; this is $version. Settings added after $version are ignored until you update. Saving from the dashboard is blocked while the configuration contains unknown keys."
        return 0
    fi
    if ! config_version_ok "$stamp"; then
        warn "config_version is malformed — treating it as 2.0.0."
    fi
    [ "$PITHEAD_DRY_RUN" -eq 0 ] || return 0
    # Presence matters: an absent stamp means 2.0.0, but still needs to be written.
    if [ "$stamp" = "$version" ] && jq -e --arg version "$version" 'if .config_version == $version then true else false end' "$CONFIG_FILE" >/dev/null; then return 0; fi
    owner=$(stat -c '%u:%g' "$CONFIG_FILE" 2>/dev/null || stat -f '%u:%g' "$CONFIG_FILE" 2>/dev/null) || owner=""
    tmp=$(mktemp "${CONFIG_FILE}.version.XXXXXXXXXX") || {
        warn "Could not write config_version — continuing without a stamp."
        return 0
    }
    if (
        umask 077
        jq --arg version "$version" '.config_version = $version' "$CONFIG_FILE" >"$tmp"
    ) &&
        chmod 600 "$tmp" && { [ -z "$owner" ] || chown "$owner" "$tmp"; } && mv -- "$tmp" "$CONFIG_FILE"; then
        return 0
    fi
    rm -f -- "$tmp"
    warn "Could not write config_version — continuing without a stamp."
}

# Return a bounded, value-only refusal for either restore door before promotion.
restore_config_version_error() {
    local stamp version
    stamp=$(jq -r '.config_version // "2.0.0"' "$1" 2>/dev/null) || return 0
    version=$(config_code_version) || return 0
    if config_version_ok "$stamp" && semver_newer "$stamp" "$version"; then
        printf "This backup's configuration was written by pithead %s; this machine runs %s. Update to %s or later, then restore." "$stamp" "$version" "$stamp"
    fi
    return 0
}
