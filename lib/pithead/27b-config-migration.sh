# shellcheck shell=bash
readonly CONFIG_MIGRATION_2_1_JQ='
def p: split(".");
def unset($c; $path): ($c | getpath($path | p)) == null;
. as $cfg
| ($table.profiles.balance | keys) as $governed
| ($table.values * (if $platform == "appliance" then $table.appliance else {} end)) as $defaults
| ($table.migrations["2.1.0"].v2_absent | map(select((.platform // $platform) == $platform))) as $v2
| def old($path):
    if unset($cfg; $path) then
        ($v2 | map(select(.path == $path)) | if length > 0 then .[0].value else ($defaults | getpath($path | p)) end)
    else ($cfg | getpath($path | p)) end;
  def clash($path; $name):
    ($table.profiles[$name][$path]) as $row
    | if $row == "auto" then old($path) == "" else old($path) != $row end;
  (["balance", "performance", "privacy"]
      | map(select(. as $name | [$governed[] as $k | select(clash($k; $name))] | length == 0))
      | .[0] // "balance") as $chosen
| ($table.profiles[$chosen]) as $row
| reduce (($governed + ($v2 | map(.path))) | unique)[] as $path (.profile = $chosen;
    if unset($cfg; $path) then
        (if ($row | has($path)) then $row[$path] else ($defaults | getpath($path | p)) end) as $new
        | if old($path) != $new then setpath($path | p; old($path)) else . end
    else . end)'

config_migration_2_1_due() {
    local stamp
    stamp=$(jq -r '.config_version // "2.0.0"' "$CONFIG_FILE" 2>/dev/null) || return 1
    config_version_ok "$stamp" || stamp=2.0.0
    semver_newer 2.1.0 "$stamp" || return 1
    jq -e 'if .profile == null or .profile == false then true else false end' "$CONFIG_FILE" >/dev/null 2>&1
}

migrate_config_to_2_1() {
    local migrated owner tmp="${CONFIG_FILE}.tmp"
    [ -f "$CONFIG_FILE" ] || return 0
    config_migration_2_1_due || return 0
    migrated=$(jq --argjson table "$(config_defaults_json)" --arg platform "$(config_platform)" \
        "$CONFIG_MIGRATION_2_1_JQ" "$CONFIG_FILE") || error "Could not compute the 2.1.0 configuration migration for $CONFIG_FILE. Nothing was changed."
    [ "$PITHEAD_DRY_RUN" -eq 0 ] || return 0
    if ! cp -p "$CONFIG_FILE" "${CONFIG_FILE}.bak-2.0" 2>/dev/null || ! chmod 600 "${CONFIG_FILE}.bak-2.0"; then
        error "Could not back up $CONFIG_FILE before migrating it to the 2.1.0 layout. Refusing: the migration pins settings 2.0.0 left implicit. Free space or fix the permissions on the config directory, then re-run."
    fi
    owner=$(stat -c '%u:%g' "$CONFIG_FILE" 2>/dev/null || stat -f '%u:%g' "$CONFIG_FILE" 2>/dev/null) || owner=""
    if (
        umask 077
        printf '%s\n' "$migrated" >"$tmp"
    ) && chmod 600 "$tmp" && mv -- "$tmp" "$CONFIG_FILE"; then
        if [ -n "$owner" ]; then chown "$owner" "$CONFIG_FILE" 2>/dev/null || true; fi
        log "Migrated $CONFIG_FILE to the 2.1.0 layout: profile $(jq -r .profile "$CONFIG_FILE"), with the settings 2.0.0 left implicit pinned so this machine behaves as before. The old copy is at ${CONFIG_FILE}.bak-2.0."
    else
        rm -f "$tmp"
        error "Could not write the 2.1.0 configuration migration to $CONFIG_FILE. The pre-migration copy is at ${CONFIG_FILE}.bak-2.0."
    fi
}
