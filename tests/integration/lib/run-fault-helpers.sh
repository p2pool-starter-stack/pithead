# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
_rig_active_pool() {
    printf 'header = %s\n' "$(printf 'Authorization: Bearer %s' "${IT_RIG_TOKEN:-}" | jq -Rs .)" |
        rx "curl -fsS --max-time 10 -K - $(quote_arg "http://$RIG_HOST:8081/1/summary")" --stdin 2>/dev/null |
        jq -r '.connection.pool // empty' 2>/dev/null
}
_pred_rig_pool_differs() {
    local pool
    pool="$(_rig_active_pool)"
    [ -n "$pool" ] && [ "$pool" != "$RIG_POOL_BEFORE" ]
}
_pred_rig_pool_returned() { [ "$(_rig_active_pool)" = "$RIG_POOL_BEFORE" ]; }
_rig_pool_leg() {
    if wait_for "$1" 10 "$3" "$2"; then
        it_pass "$3"
    else
        it_fail "$3" "the rig's active pool did not change as expected within $1s"
    fi
}
_assert_dashboard_logged() {
    local label="$1" pattern="$2" line
    line="$(rx "docker compose logs --no-color dashboard 2>&1 | grep -aE $(quote_arg "$pattern") | tail -n 1 | cut -c 1-400" 2>/dev/null)"
    if [ -n "$line" ]; then
        it_step "dashboard log: ${line}"
        it_pass "$label"
    else
        it_fail "$label" "no dashboard log line matching ${pattern}"
    fi
}
