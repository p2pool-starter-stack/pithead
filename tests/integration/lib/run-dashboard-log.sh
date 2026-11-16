# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
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
