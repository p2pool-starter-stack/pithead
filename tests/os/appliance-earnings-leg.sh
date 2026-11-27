# shellcheck shell=bash
# Verify the provisioned dashboard serves this checkout's calculator and parser through Caddy.
phase_provision_earnings_assets() { # <captured-dashboard-user> <captured-dashboard-password>
    # dashboard_curl uses these through Bash's dynamic scope without putting them in argv.
    # shellcheck disable=SC2034
    local DASH_USER="$1" DASH_PASS="$2"
    local asset expected served rc=0
    [ -n "$DASH_USER" ] && [ -n "$DASH_PASS" ] || {
        bad "earnings assets NOT exercised: captured dashboard login is missing (#3261)"
        return 1
    }
    for asset in app/logic.mjs app/earnings.mjs; do
        if ! expected=$(cat "$SCRIPT_DIR/../../dashboard/mining_dashboard/web/static/$asset") || [ -z "$expected" ]; then
            bad "earnings asset source is unreadable or empty: $asset (#3261)"
            return 1
        fi
        if ! served=$(address_watch_dashboard_asset "$asset") || [ -z "$served" ]; then
            bad "served earnings asset is unreadable, empty or not HTTP 200: $asset (#3261)"
            rc=1
        elif [ "$served" = "$expected" ]; then
            ok "served earnings asset matches the tested checkout: $asset (#3261)"
        else
            bad "served earnings asset differs from the tested checkout: $asset (#3261)"
            rc=1
        fi
    done
    return "$rc"
}
