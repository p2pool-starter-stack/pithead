# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# A fresh spare must not gain reset authority merely because its setup page opens.
_update_spare_slot_uncommitted() {
    if _wait_setup_page 120; then
        local spare_status spare_until=$((SECONDS + 120))
        while [ "$SECONDS" -lt "$spare_until" ]; do
            spare_status=$(SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh 'rauc status --output-format=json') || spare_status=""
            printf '%s' "$spare_status" | jq -e '.booted == "B" and any(.slots[]; .["rootfs.1"].state == "booted" and .["rootfs.1"].boot_status == "bad")' >/dev/null 2>&1 && break
            sleep 5
        done
        if [ "$SECONDS" -lt "$spare_until" ]; then
            ok "unprovisioned B with its setup page open remains uncommitted"
        else
            bad "unprovisioned B was committed or its RAUC state never became readable"
        fi
    else
        bad "unprovisioned update setup page never served"
    fi
}
