# Shared new-install disk rule. Both wizards use the same component budgets.
wizard_stack_need_gib() { # <monero-mode>
    local need=0 comp
    for comp in tari p2pool dashboard tor; do
        need=$((need + $(disk_component_gib "$comp")))
    done
    [ "$1" == "remote" ] || need=$((need + $(disk_component_gib monero 1)))
    echo "$need"
}

# Does this machine's data disk already hold a Tari chain? Half the Tari budget is the line: a
# fresh or abandoned sync sits well below it, a synced chain well above. The one input that turns
# the wizards' Enter default for Tari from "off" back to "local" (#3333). TARI_DIR is the
# configured location when a config is loaded; the wizard runs before one exists, so ./data/tari.
wizard_tari_chain_held() {
    local dir="${TARI_DIR:-$PWD/data/tari}" kb
    [ -d "$dir" ] || return 1
    kb=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
    [[ "$kb" =~ ^[0-9]+$ ]] && [ "$kb" -ge "$(($(disk_component_gib tari) * 1048576 / 2))" ]
}

# Host measurement, never the wizard container's overlay filesystem. Installer targets
# carry their own capacity in disks.tsv; this value is for an already booted data disk.
wizard_disk_budget() {
    local mount kb="" bytes=null
    mount=$(disk_fs_mount "$PWD/data" 2>/dev/null) || mount=""
    if [ -n "$mount" ]; then
        kb=$(df -P "$mount" 2>/dev/null | awk 'NR==2{print $4}') || kb=""
        [[ "$kb" =~ ^[0-9]+$ ]] && bytes=$((kb * 1024))
    fi
    local held=false
    wizard_tari_chain_held && held=true
    jq -n --argjson available "$bytes" --argjson held "$held" \
        --argjson local_need "$(wizard_stack_need_gib local)" \
        --argjson remote_need "$(wizard_stack_need_gib remote)" \
        '{available_bytes: $available, local_need_bytes: ($local_need * 1073741824),
          remote_need_bytes: ($remote_need * 1073741824),
          tari_chain_held: $held}'
}
