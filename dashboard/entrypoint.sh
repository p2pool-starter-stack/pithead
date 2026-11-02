#!/bin/bash
set -e

# We no longer dynamically fetch the LAN IP here because the dashboard
# MUST be bound to localhost (127.0.0.1) to remain secure behind Caddy.
# The HOST_IP variable is now injected directly via docker-compose.yml.

# Fallback to localhost if the variable is somehow missing
export HOST_IP="${HOST_IP:-127.0.0.1}"

cd /app
case "${PITHEAD_IMPL:-python}" in
bash | python)
    exec python3 -u -m mining_dashboard.main
    ;;
go)
    exec "${PITHEAD_DASHBOARD_GO_BINARY:-/app/go/bin/dashboard}"
    ;;
*)
    echo "Unsupported PITHEAD_IMPL: ${PITHEAD_IMPL}" >&2
    exit 2
    ;;
esac
