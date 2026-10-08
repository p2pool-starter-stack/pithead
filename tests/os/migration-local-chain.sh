# shellcheck shell=bash
# The runner provides a consistent Monero-only copy; this leg never reads a live source.
migration_snapshot_input() {
    local metadata gib
    [ -n "${PITHEAD_OS_MONERO_SNAPSHOT:-}" ] || {
        bad "local-chain migration fixture is unavailable; an earned release cannot be seeded"
        return 1
    }
    metadata=$(python3 "$SCRIPT_DIR/migration-monero-snapshot.py" validate "$PITHEAD_OS_MONERO_SNAPSHOT") || {
        bad "local-chain migration snapshot failed its consistency and integrity contract"
        return 1
    }
    read -r MIGRATION_SNAPSHOT_SIZE MIGRATION_SNAPSHOT_HEIGHT MIGRATION_SNAPSHOT_SHA <<<"$metadata"
    gib=${PITHEAD_OS_MONERO_SNAPSHOT_GUEST_GIB:-}
    [[ "$gib" =~ ^[1-9][0-9]{1,3}$ ]] || return 1
    case "$gib" in '' | *[!0-9]* | ?????*)
        bad "local-chain fixture has no valid runner-reserved guest capacity"
        return 1
        ;;
    esac
    [ "$gib" -ge 40 ] && [ "$gib" -le 8192 ] &&
        [ "$((gib * 1073741824))" -ge "$((MIGRATION_SNAPSHOT_SIZE + 42949672960))" ] || {
        bad "local-chain fixture exceeds its runner-reserved guest capacity"
        return 1
    }
}

migration_services_healthy() {
    _ssh "test \"\$(sed -n 's/^MONERO_MODE=//p' /data/pithead/.env)\" = local && podman inspect monerod p2pool xmrig-proxy | jq -e 'length == 3 and all(.[]; .State.Running == true and .State.Health.Status == \"healthy\")' >/dev/null"
}

migration_wait_for_mining() { # <guest timestamp>; two fresh readings with an increasing hash counter
    local since="$1" deadline=$(($(date +%s) + 1800)) payload sample hashes previous=0
    payload=$(base64 <"$SCRIPT_DIR/migration-readiness.py" | tr -d '\n')
    while [ "$(date +%s)" -lt "$deadline" ]; do
        sample=$(SSH_TIMEOUT=20 _ssh "printf %s '$payload' | base64 -d | podman exec -i dashboard python3 - '$since' '$MIGRATION_SNAPSHOT_HEIGHT'" 2>/dev/null) || sample=""
        read -r _ _ hashes <<<"$sample"
        if [[ "$sample" =~ ^ready\ [0-9]+\ [0-9]+$ ]] && migration_services_healthy; then
            [ "$previous" -gt 0 ] && [ "$hashes" -gt "$previous" ] && return 0
            previous=$hashes
        else
            previous=0
        fi
        sleep 5
    done
    return 1
}

migration_prepare_local_chain() {
    local address port live proposed result payload since available
    address=$(getent ahostsv4 "${PITHEAD_OS_TARI_NODE_HOST:-}" | awk 'NR==1 {print $1}')
    port=${PITHEAD_OS_TARI_GRPC_PORT:-}
    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    case "$port" in '' | *[!0-9]* | ??????*) return 1 ;; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    # Match the reported local-Monero/remote-Tari deployment without replacing Monero.
    live=$(sensitive_live_config) && approval_capture_restore_snapshot || return 1
    proposed=$(printf %s "$live" | jq -c --arg host "$address" --argjson port "$port" \
        '.tari.mode="remote" | .tari.remote.host=$host | .tari.remote.grpc_port=$port') || return 1
    sensitive_preview "$(dashboard_config_body "$proposed")" || return 1
    result=$(approval_commit "$APPROVAL_REQUEST_ID") && tari_commit_verdict "$result" || return 1
    available=$(_ssh "df -PB1 /data | awk 'NR==2 {print \$4}'" | tr -d '\r\n') || return 1
    [[ "$available" =~ ^[0-9]+$ ]] && [ "$available" -gt "$((MIGRATION_SNAPSHOT_SIZE + 5368709120))" ] || return 1
    # shellcheck disable=SC2154 # ip is the reserved guest address from the suite.
    timeout 3600 scp -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$PITHEAD_OS_MONERO_SNAPSHOT/data.mdb" "root@$ip:/data/pithead-migration-copy.mdb" >/dev/null 2>&1 || return 1
    payload=$(base64 <"$SCRIPT_DIR/migration-monero-snapshot.py" | tr -d '\n')
    if ! _ssh "set -eu
cd /data/pithead
test \"\$(sed -n 's/^MONERO_MODE=//p' .env)\" = local
d=\$(sed -n 's/^MONERO_DATA_DIR=//p' .env)
test -n \"\$d\"
podman stop dashboard monerod p2pool xmrig-proxy >/dev/null
printf %s '$payload' | base64 -d | python3 - install /data/pithead-migration-copy.mdb \"\$d\" '$MIGRATION_SNAPSHOT_SHA'
./pithead up >/dev/null"; then
        return 1
    fi
    since=$(_ssh 'date +%s' | tr -d '\r\n') || return 1
    [[ "$since" =~ ^[0-9]+$ ]] && migration_wait_for_mining "$since" || return 1
    ok "isolated local Monero is synced and mining earned its persisted release before upgrade"
    payload=$(base64 <"$SCRIPT_DIR/migration-release-snapshot.py" | tr -d '\n')
    _ssh "printf %s '$payload' | base64 -d | podman exec -i dashboard python3 - /data/mining_data.db" || return 1
    ok "the pre-upgrade database already contains the earned miner_released=true latch"
}
