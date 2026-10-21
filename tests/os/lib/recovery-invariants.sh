# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"

recovery_slot_matches() {
    local snapshot="$1" slot="$2" marker="$3" source="$4" other=A primary=rootfs.1 status
    [ "$slot" = B ] || {
        other=B
        primary=rootfs.0
    }
    [ "${snapshot%%$'\n'*}" = "$slot|$marker|$source" ] || return 1
    grep -qx "${slot}_OK=1" <<<"$snapshot" && grep -qx "${slot}_TRY=0" <<<"$snapshot" || return 1
    if [ "${5:-both}" = both ]; then
        grep -qx "${other}_OK=1" <<<"$snapshot" && grep -qx "${other}_TRY=0" <<<"$snapshot" &&
            grep -qx "ORDER=$slot $other" <<<"$snapshot" || return 1
    fi
    status=$(sed -n '/^{/,$p' <<<"$snapshot")
    jq -e --arg slot "$slot" --arg primary "$primary" --arg mode "${5:-both}" '
        .booted == $slot and .boot_primary == $primary and
        any(.slots[]; .[$primary].boot_status == "good") and
        ($mode != "both" or ([.slots[] | to_entries[] | .value.boot_status] == ["good", "good"]))' <<<"$status" >/dev/null 2>&1
}

recovery_ids_disjoint() {
    local before="$1" after="$2" id
    [ -n "$before" ] || return 1
    while IFS= read -r id; do
        [[ "$id" =~ ^[0-9a-f]{64}$ ]] || return 1
        ! grep -Fxq "$id" <<<"$after" || return 1
    done <<<"$before"
    if [ -n "$after" ]; then
        while IFS= read -r id; do [[ "$id" =~ ^[0-9a-f]{64}$ ]] || return 1; done <<<"$after"
    fi
}

_recovery_wait_slot() {
    local until=$((SECONDS + ${5:-900})) snapshot
    while [ "$SECONDS" -lt "$until" ]; do
        snapshot=$(_reset_slot_snapshot) || snapshot=""
        if recovery_slot_matches "$snapshot" "$1" "$2" "$3" "${4:-both}" &&
            SSH_TIMEOUT=20 _ssh "journalctl -b -u pithead-boot --no-pager | grep -q 'booted slot committed'"; then
            return 0
        fi
        sleep 5
    done
    printf 'recovery slot snapshot:\n%s\n' "$snapshot" >&2
    return 1
}

_slot_invariant_reboot() {
    local label="$1"
    if _reboot_wait reboot 300 && _recovery_wait_slot B recovery "$RECOVERY_HEAD" &&
        _reboot_wait reboot 300 && _recovery_wait_slot B recovery "$RECOVERY_HEAD"; then
        ok "$label: committed candidate and fallback survive the extra reboot"
    else
        bad "$label: committed candidate and fallback survive the extra reboot"
        return 1
    fi
}

_recovery_fallback_intact() {
    SSH_TIMEOUT=30 _ssh 'set -e
mkdir -p /run/recovery-fallback
mount -o ro /dev/disk/by-partlabel/system-a /run/recovery-fallback
trap "umount /run/recovery-fallback" EXIT
cat /run/recovery-fallback/opt/pithead/BUILD_COMMIT' | grep -Fxq "$RECOVERY_OLD_SOURCE"
}

_recovery_project_ids() {
    SSH_TIMEOUT=20 _ssh "podman ps -a --no-trunc --filter label=com.docker.compose.project=pithead --format '{{.ID}}'"
}

_recovery_identity() {
    SSH_TIMEOUT=30 _ssh 'set -e; set -o pipefail; cd /data/pithead
jq -cS . config.json | sha256sum | cut -d" " -f1
values=$(grep -E "^(MONERO_WALLET_ADDRESS|MONERO_VIEW_KEY|TARI_WALLET_ADDRESS|TARI_WALLET_PASSWORD|TARI_VIEW_KEY|TARI_SPEND_PUBLIC_KEY|PROXY_AUTH_TOKEN|PROXY_STRATUM_PASSWORD|XMRIG_API_TOKEN|DASHBOARD_AUTH_USER|DASHBOARD_AUTH_HASH_B64|DASHBOARD_AUTH_PW_FP|MONERO_NODE_USERNAME|MONERO_NODE_PASSWORD|WALLET_RPC_USERNAME|WALLET_RPC_PASSWORD|[A-Z]+_ONION_ADDRESS|DASHBOARD_ONION_CLIENT_(PUBKEY|PRIVKEY))=" .env | sort)
test -n "$values"
printf "%s\n" "$values" | sha256sum | cut -d" " -f1'
}

recovery_identity_matches() {
    local first second extra
    IFS=$'\n' read -r -d '' first second extra <<<"$1" || true
    [[ "$first" =~ ^[0-9a-f]{64}$ ]] && [[ "$second" =~ ^[0-9a-f]{64}$ ]] &&
        [ -z "$extra" ] && [ "$1" = "$2" ]
}

_recovery_post_op() {
    local label="$1" before="$2" until=$((SECONDS + 120)) after
    while [ "$SECONDS" -lt "$until" ]; do
        if after=$(_recovery_project_ids) && recovery_ids_disjoint "$before" "$after"; then
            ok "$label: no pre-operation project container survives"
            return 0
        fi
        sleep 5
    done
    bad "$label: no pre-operation project container survives"
    return 1
}
