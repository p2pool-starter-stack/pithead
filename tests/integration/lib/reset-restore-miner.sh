# shellcheck shell=bash
rr_miner_workers() {
    local script
    script=$(
        cat <<'PY'
import json, os
from mining_dashboard.helper.http import bounded_get
r = bounded_get('http://{}:{}/1/workers'.format(os.environ['PROXY_HOST'], os.environ['PROXY_API_PORT']), headers={'Authorization': 'Bearer ' + os.environ['PROXY_AUTH_TOKEN']}, timeout=5)
r.raise_for_status()
rows = r.json()['workers']
assert type(rows) is list
for row in rows:
    assert type(row) is list and len(row) >= 4 and type(row[0]) is str
    assert all(type(v) is int and v >= 0 for v in row[2:4])
print(json.dumps(rows))
PY
    )
    printf -v script '%q' "$script"
    rx "timeout --kill-after=2 15 docker compose exec -T dashboard python3 -c $script"
}

rr_miner_state() {
    [ "$RR_MINER_ENABLED" = 1 ] || return 0
    local state
    if ! state=$(rx 'timeout --kill-after=2 10 systemctl show xmrig.service -p LoadState -p ActiveState -p SubState -p Result -p ExecMainStatus'); then
        it_fail "reset recovery captures host-miner unit state" "bounded systemctl read failed at $1"
        return 1
    fi
    {
        printf '%s\n' "$1"
        printf '%s\n' "$state"
    } >>"$OUT_DIR/reset-restore.miner-state.log"
}

rr_miner_online() {
    local rows names
    rows=$(rr_miner_workers) || return 1
    names=$(jq -ce '[.[] | select(.[2] >= 1) | .[0]] | unique' <<<"$rows") || return 1
    jq -e --arg name "$RR_MINER_LOCAL" 'length > 0 and index($name) != null' <<<"$names" >/dev/null || return 1
    RR_MINER_NAMES=$names
}

rr_miner_prepare() {
    local mode
    if [ "${SKIP_MINING_ASSERTS:-0}" = 1 ]; then
        it_skip_leg "reset recovery reinstates the enabled appliance miner" "SKIP_MINING_ASSERTS=1" by-design
        return 0
    fi
    mode=$(rx 'source ./pithead || exit; if is_appliance && [ "$(config_bool '\''.local_miner.enabled'\'' false)" = true ]; then printf enabled; else printf disabled; fi') || return 1
    case "$mode" in
    disabled)
        it_skip_leg "reset recovery reinstates the enabled appliance miner" "DIY or local mining disabled" by-design
        return 0
        ;;
    enabled) RR_MINER_ENABLED=1 ;;
    *) return 1 ;;
    esac
    RR_MINER_LOCAL=$(rx "jq -er '.pools[0].user | select(type == \"string\" and length > 0)' /data/rigforge/data/worker/xmrig/build/config.json") || return 1
    rr_miner_state before-reset || return 1
    rx 'timeout --kill-after=2 10 systemctl is-active --quiet xmrig.service' || return 1
    wait_for 240 5 "online local miner before reset recovery" rr_miner_online
}

rr_miner_returned() {
    local rows
    rows=$(rr_miner_workers) || return 1
    jq -e --argjson names "$RR_MINER_NAMES" --argjson shares "$1" --argjson baseline "${RR_MINER_BASELINE:-[]}" '
        . as $workers | all($names[]; . as $name |
            any($workers[]; .[0] == $name and .[2] >= 1) and
            (if $shares then
                ([$workers[] | select(.[0] == $name) | .[3]] | add // 0) >
                ([$baseline[] | select(.[0] == $name) | .[3]] | add // 0)
             else true end))' <<<"$rows" >/dev/null || return 1
    [ "$1" != false ] || RR_MINER_BASELINE=$rows
}

rr_miner_recovered() {
    [ "$RR_MINER_ENABLED" = 1 ] || return 0
    rr_miner_state after-up || return 1
    if ! wait_for "${BOUND_RECONNECT:-480}" 5 "reset recovery workers reconnect" rr_miner_returned false; then
        rr_miner_state reconnect-timeout || true
        it_fail "reset recovery workers reconnect" "saved nonempty worker set did not reconnect within BOUND_RECONNECT"
        return 1
    fi
    if ! wait_for 600 5 "reset recovery workers accept new shares" rr_miner_returned true; then
        rr_miner_state share-timeout || true
        it_fail "reset recovery workers accept new shares" "a saved worker did not accept a post-reset share within 600 seconds"
        return 1
    fi
    rr_miner_state recovered || return 1
    it_pass "reset recovery reinstates the local miner and saved workers with new accepted shares"
}
