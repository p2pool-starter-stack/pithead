# shellcheck shell=bash
# The exact RC2 baseline is a verified runner input, never a mutable version tag.
MIGRATION_RC2_COMMIT=f5a5ad096c7a5345609a2eed4f600fd750a425ab
migration_rc2_input() {
    [ -f "${PITHEAD_OLD_IMAGE:-}" ] && [ "${PITHEAD_OLD_IMAGE_COMMIT:-}" = "$MIGRATION_RC2_COMMIT" ] &&
        [[ "${PITHEAD_OLD_DASHBOARD_IMAGE:-}" =~ ^[a-z0-9][a-z0-9._:/-]*@sha256:[0-9a-f]{64}$ ]]
}

migration_prepare_rc2() {
    migration_rc2_input || {
        bad "the verified exact RC2 baseline hand-off is unavailable"
        return 1
    }
    _vm_boot_disk "$PITHEAD_OLD_IMAGE" && _wait_ssh 900 || return 1
    [ "$(_ssh 'cat /opt/pithead/BUILD_COMMIT' | tr -d '\r\n')" = "$MIGRATION_RC2_COMMIT" ] || return 1
    _wizard_provision_capture 0 || return 1
    # The captured old-image login replaces the credentials of the disposable initial guest.
    # shellcheck disable=SC2034 # phase-scoped credentials are used by all later legs.
    pv_user="$DASH_USER" pv_pass="$DASH_PASS"
    provisioning_settled 900 && ! provisioning_setup_failed || return 1
    _ssh "actual=\$(podman inspect dashboard --format '{{.Image}}')
expected=\$(podman image inspect '$PITHEAD_OLD_DASHBOARD_IMAGE' --format '{{.Id}}')
test -n \"\$expected\" && test \"\$actual\" = \"\$expected\"" || return 1
    local live proposed result
    live=$(sensitive_live_config) || return 1
    proposed=$(printf %s "$live" | jq -c '.dashboard.host="fixture-next" | .local_miner.enabled=true | .xvb.enabled=false | .monero.mode="local" | .tari.mode="local"') || return 1
    sensitive_preview "$(dashboard_config_body "$proposed")" || return 1
    result=$(approval_commit "$APPROVAL_REQUEST_ID") && tari_commit_verdict "$result" || return 1
    _ssh "test \"\$(sed -n 's/^MONERO_MODE=//p' /data/pithead/.env)\" = local" || return 1
    ok "verified RC2 baseline and immutable dashboard are provisioned with local chains and a miner"
}

migration_seed_rc2() {
    local payload image persisted=0
    payload=$(base64 <"$SCRIPT_DIR/migration-release-snapshot.py" | tr -d '\n')
    image=$(_ssh "podman inspect dashboard --format '{{.Image}}'" | tr -d '\r\n') || return 1
    [[ "$image" =~ ^(sha256:)?[0-9a-f]{64}$ ]] || return 1
    # The old dashboard persists periodically; a fresh provision must have a real snapshot
    # before its writer is stopped. Read only, with a bounded wait rather than a replacement DB.
    for _ in $(seq 30); do
        if _ssh "podman exec dashboard python3 -c 'import json, sqlite3; from mining_dashboard.config.config import DB_FILE_PATH; db=sqlite3.connect(\"file:\"+DB_FILE_PATH+\"?mode=ro\", uri=True); row=db.execute(\"SELECT value FROM kv_store WHERE key = ?\", (\"snapshot_latest_data\",)).fetchone(); value=json.loads(row[0]) if row else None; raise SystemExit(0 if isinstance(value, dict) and value else 1)'"; then
            persisted=1
            break
        fi
        sleep 2
    done
    [ "$persisted" = 1 ] || return 1
    # Stop the only writer, retain its existing mount and identity, and never restart it pre-upgrade.
    _ssh "podman stop dashboard >/dev/null && printf %s '$payload' | base64 -d | podman run --rm -i --network none --volumes-from dashboard --user 1000:1000 --entrypoint python3 '$image' -" || return 1
    ok "the RC2 writer seeded its existing release snapshot without changing database ownership or mode"
}

migration_services_healthy() {
    _ssh "podman inspect p2pool xmrig-proxy | jq -e 'length == 2 and all(.[]; .State.Running == true and .State.Health.Status == \"healthy\")' >/dev/null && systemctl is-active --quiet xmrig"
}

migration_wait_for_mining() { # <guest timestamp>; fresh readings must show advancing hashes
    local since="$1" deadline=$(($(date +%s) + 1800)) payload sample hashes previous=0
    payload=$(base64 <"$SCRIPT_DIR/migration-readiness.py" | tr -d '\n')
    while [ "$(date +%s)" -lt "$deadline" ]; do
        sample=$(SSH_TIMEOUT=20 _ssh "printf %s '$payload' | base64 -d | podman exec -i dashboard python3 - '$since'" 2>/dev/null) || sample=""
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

migration_remote_recovery() {
    local live proposed result port
    local mh="${PITHEAD_OS_MONERO_NODE_HOST:-}" rpc="${PITHEAD_OS_MONERO_RPC_PORT:-}" zmq="${PITHEAD_OS_MONERO_ZMQ_PORT:-}"
    local th="${PITHEAD_OS_TARI_NODE_HOST:-}" grpc="${PITHEAD_OS_TARI_GRPC_PORT:-}"
    [ -n "$mh" ] && [ -n "$th" ] || return 1
    for port in "$rpc" "$zmq" "$grpc"; do
        [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] || return 1
    done
    approval_capture_restore_snapshot && reserved_node_clearnet_fixture || return 1
    live=$(sensitive_live_config) || return 1
    proposed=$(remote_node_proposal "$live" "$mh" "$rpc" "$zmq" "${PITHEAD_OS_MONERO_NODE_USERNAME:-}" "${PITHEAD_OS_MONERO_NODE_PASSWORD:-}" "$th" "$grpc") || return 1
    sensitive_preview "$(dashboard_config_body "$proposed")" || return 1
    result=$(approval_commit "$APPROVAL_REQUEST_ID") && tari_commit_verdict "$result"
}
