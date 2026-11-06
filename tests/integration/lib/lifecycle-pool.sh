# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

lifecycle_pool_flags_match() {
    rx "grep -qE '^P2POOL_FLAGS=' .env" && pool_flags_correct "$1"
}

lifecycle_pool_start() {
    local pool
    if ! pool="$(rx "jq -er 'if type == \"object\" then (.p2pool.pool | if . == null then \"mini\" else . end) else error(\"invalid config\") end | select(. == \"main\" or . == \"mini\" or . == \"nano\")' config.json")"; then
        it_fail "pool change starting config readable" "cannot determine the deployed sidechain" >&2
        return 1
    fi
    if ! wait_for 180 5 "starting pool flags" lifecycle_pool_flags_match "$(pool_label "$pool")" >&2; then
        it_fail "pool change starting flags match config" "rendered flags do not establish the starting sidechain" >&2
        return 1
    fi
    printf '%s' "$pool"
}

lifecycle_pool_apply() {
    local config
    if ! config="$(render_scenario_config "$BASELINE_CONFIG" "p2pool.pool=$1")" || ! push_config "$config" ||
        ! pithead apply -y >/dev/null 2>&1 || ! wait_status_ok 180; then
        it_fail "pool change apply returned healthy" "config push, apply or readiness failed"
        return 1
    fi
    if ! wait_for 180 5 "changed pool flags" lifecycle_pool_flags_match "$(pool_label "$1")"; then
        it_fail "pool change rendered the alternate sidechain" "rendered flags did not change to the selected pool"
        return 1
    fi
}
