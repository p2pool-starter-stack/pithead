: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
_normalize_config_version() {
    local s c a b t
    s=$(rx 'jq -r ".config_version // empty" config.json 2>/dev/null') || s=""
    c=$(rx 'tr -d " \t\r\n" < VERSION 2>/dev/null') || c=""
    [ -n "$s" ] && [ -n "$c" ] || return 0
    printf '%s' "$s" | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+$' || return 0
    printf '%s' "$c" | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+$' || return 0
    a=$(printf '%s' "${s#v}" | awk -F. '{printf "%d%05d%05d",$1,$2,$3}')
    b=$(printf '%s' "${c#v}" | awk -F. '{printf "%d%05d%05d",$1,$2,$3}')
    [ "$a" -gt "$b" ] || return 0
    t=$(rx 'mktemp config.json.XXXXXXXXXX') || return 1
    if rx "jq --arg v '$c' '.config_version = $v' config.json > '$t'" &&
        rx "mv '$t' config.json"; then it_log "Normalized config_version stamp $s to $c" 2>/dev/null || true; else rx "rm -f '$t'"; fi
}
