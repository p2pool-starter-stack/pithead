# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

_backup_node_serving() {
    local state
    rx "timeout 15 docker logs --tail 1000 --since $(quote_arg "$backup_fault_since") p2pool 2>&1 | grep -Fq 'connected to tcp://127.0.0.2:$backup_zmq'" || return 1
    state=$(api_state) || return 1
    printf '%s' "$state" | jq -e --argjson height "$backup_height" '
        .network.height > $height and
        ([.badges[]?.text | select(test("^(Workers rejected|Miner held)"))] | length == 0)' >/dev/null || return 1
    [ "$(svc_state_of "$(service_state xmrig-proxy)")" = running ] &&
        [ "$(rx "docker inspect -f '{{.State.StartedAt}}' xmrig-proxy")" = "$backup_proxy_started" ]
}

fault_monero_backups() {
    local original candidate backup_zmq backup_height backup_fault_since backup_proxy_started failures="$IT_FAIL"
    if [ -z "${REMOTE_MONERO_HOST:-}" ]; then
        it_skip_leg "Monero backup primary-down failover" "no approved external Monero provider was supplied" missing
        return
    fi
    original=$(rx 'cat config.json') || {
        it_fail "Monero backup fixture captured config" "read failed"
        return
    }
    backup_zmq="${REMOTE_MONERO_ZMQ_PORT:-18083}"
    candidate=$(printf '%s' "$original" | jq --arg host "$REMOTE_MONERO_HOST" \
        --argjson rpc "${REMOTE_MONERO_RPC_PORT:-18081}" --argjson zmq "$backup_zmq" '
        .monero.mode = "local" | .p2pool.clearnet = false | .network.tor_egress_firewall = true
        | .monero.backup_nodes = [{host:$host, rpc_port:$rpc, zmq_port:$zmq}
            + (if (.monero.node_username // "") == "" then {} else
               {rpc_login:(.monero.node_username + ":" + (.monero.node_password // ""))} end)]') || return 1
    if ! push_config "$candidate" || ! pithead apply -y >/dev/null 2>&1 ||
        ! wait_for 240 5 "primary ready before backup failover" _pred_failover_armed; then
        it_fail "Monero backup fixture starts with the primary ready" "configuration or readiness failed"
    else
        assert_eq "Monero backup proof keeps the firewall on" "$(env_on_box TOR_EGRESS_FIREWALL)" true
        assert_eq "Monero backup proof keeps Tor routing on" "$(env_on_box P2POOL_CLEARNET)" false
        backup_height=$(jq_get "$(api_state)" '.network.height')
        backup_proxy_started=$(rx "docker inspect -f '{{.State.StartedAt}}' xmrig-proxy")
        backup_fault_since=$(rx 'date -u +%Y-%m-%dT%H:%M:%SZ')
        if [ -n "$backup_height" ] && [ -n "$backup_proxy_started" ] &&
            [ -n "$backup_fault_since" ] &&
            rx "timeout 15 docker logs --tail 1000 p2pool 2>&1 | grep 'connected to tcp://' | tail -n 1 | grep -Fq 'connected to tcp://127.0.0.1:'" && rx 'docker compose stop monerod' >/dev/null 2>&1; then
            if wait_for 600 5 "backup supplies new chain data with primary stopped" _backup_node_serving; then
                it_pass "P2Pool serves new chain data from its backup with primary down"
                local until=$((SECONDS + 90)) admitted=true
                while [ "$SECONDS" -lt "$until" ]; do
                    _backup_node_serving || {
                        admitted=false
                        break
                    }
                    sleep 5
                done
                assert_eq "worker listener stays admitted throughout backup failover" "$admitted" true
            else
                it_fail "P2Pool serves new chain data from its backup with primary down" "no backup connection, height progress or unchanged worker listener within 600s"
            fi
        else
            it_fail "Monero backup fault armed" "missing baseline witness or primary stop failed"
        fi
    fi
    [ "$IT_FAIL" -eq "$failures" ] || capture_artifacts monero-backups "$OUT_DIR"
    if ! rx 'docker compose start monerod' >/dev/null 2>&1 || ! push_config "$original" ||
        ! pithead apply -y >/dev/null 2>&1 || ! wait_status_ok 240; then
        it_fail "Monero backup fixture restores original config and services" "restore failed"
        return 1
    fi
    it_pass "Monero backup fixture restores original config and services"
}
