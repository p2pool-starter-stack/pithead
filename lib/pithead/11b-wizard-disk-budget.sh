# Shared new-install disk rule. Both wizards use the same component budgets.
wizard_stack_need_gib() { # <monero-mode>
    local need=0 comp
    for comp in tari p2pool dashboard tor; do
        need=$((need + $(disk_component_gib "$comp")))
    done
    [ "$1" == "remote" ] || need=$((need + $(disk_component_gib monero 1)))
    echo "$need"
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
    jq -n --argjson available "$bytes" \
        --argjson local_need "$(wizard_stack_need_gib local)" \
        --argjson remote_need "$(wizard_stack_need_gib remote)" \
        '{available_bytes: $available, local_need_bytes: ($local_need * 1073741824),
          remote_need_bytes: ($remote_need * 1073741824)}'
}
