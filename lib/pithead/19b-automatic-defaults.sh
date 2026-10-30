low_ram_floor_gb() {
    local monero tari miner
    monero=$(config_get .monero.mode)
    tari=$(config_get .tari.mode)
    miner=$(config_get .local_miner.enabled)
    config_defaults_json | jq -r --arg monero "$monero" --arg tari "$tari" --arg miner "$miner" '
        .runtime.low_ram_gb | .base + (if $monero == "local" then .monero else 0 end)
        + (if $tari == "local" then .tari else 0 end)
        + (if $miner == "true" then .miner else 0 end)'
}

host_memtotal_kb() {
    awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null
}

p2pool_needs_light_mode() {
    local total floor
    total=$(host_memtotal_kb) || return 1
    [[ "$total" =~ ^[0-9]+$ ]] && [ "$total" -gt 0 ] || return 1
    floor=$(low_ram_floor_gb) || return 1
    [ "$total" -lt "$((floor * 1024 * 1024))" ]
}
