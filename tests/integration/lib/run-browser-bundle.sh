# shellcheck shell=bash
run_browser_bundle() {
    local host port secure settings command helper_dir ctrl_config="$1" probe_rc=0
    helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tools" && pwd)"
    host="$(env_on_box HOST_IP)"
    port="$(env_on_box HOST_PORT)"
    secure="$(env_on_box DASHBOARD_SECURE)"
    if [ -z "$host" ]; then
        it_fail "browser support bundle is authorized, bounded, redacted and reviewed (#2540)" "dashboard address unavailable"
        return 1
    fi
    [ -n "$port" ] || { [ "$secure" = false ] && port=80 || port=443; }
    settings=$(printf '%s' "$ctrl_config" | jq --arg host "$host" --argjson port "$port" --arg secure "$secure" \
        '{host:$host,port:$port,secure:($secure != "false"),username:.dashboard.auth.username,password:.dashboard.auth.password}')
    command="python3 -c $(quote_arg "$(cat "$helper_dir/browser-bundle.py")")"
    printf '%s' "$settings" | rx "$command" --stdin || probe_rc=$?
    assert_rc "browser support bundle is authorized, bounded, redacted and reviewed (#2540)" "$probe_rc" 0
    return "$probe_rc"
}
