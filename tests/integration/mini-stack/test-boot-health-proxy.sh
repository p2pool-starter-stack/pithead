#!/usr/bin/env bash
# Real rendered Caddy + dashboard: boot 401s are marked, network forgeries still count.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scratch=$(mktemp -d -t pithead-boot-proxy.XXXXXX)
name="pithead-boot-proxy-$$"
cleanup() {
    docker rm -f "$name-dashboard" "$name-front" "$name-caddy" >/dev/null 2>&1 || true
    docker network rm "$name" >/dev/null 2>&1 || true
    docker volume rm "$name-logs" >/dev/null 2>&1 || true
    rm -rf "$scratch"
}
trap cleanup EXIT
# Fail when the required daemon or already-built real dashboard image is missing.
docker info >/dev/null
docker image inspect pithead-dashboard:itest >/dev/null
image=$(awk '$0 == "  caddy:" { s=1; next } s && $1 == "image:" { print $2; exit }' "$ROOT/docker-compose.yml")
# shellcheck source=lib/pithead/35-caddyfile-and-auth-helpers.sh
source "$ROOT/lib/pithead/35-caddyfile-and-auth-helpers.sh"
is_appliance() { return 1; }
appliance_site_names() { printf panel.example; }
log() { :; }
error() {
    echo "$*" >&2
    exit 1
}
export DASHBOARD_SECURE=false HOST_PORT=8080
export DASHBOARD_AUTH_HASH_B64 DASHBOARD_BOOT_PROBE_TOKEN
auth_hash=$(printf '%s\n' fixture-password | docker run --rm -i "$image" caddy hash-password)
DASHBOARD_AUTH_HASH_B64=$(printf '%s' "$auth_hash" | openssl base64 -A)
DASHBOARD_BOOT_PROBE_TOKEN=$(openssl rand -hex 32)
mkdir -p "$scratch/auth"
jq -n --arg hash "$auth_hash" '{users:[{name:"admin",role:"admin",password_hash:$hash}],metrics_password_hash:$hash}' >"$scratch/auth/auth.json"
generate_caddyfile "$scratch/Caddyfile"
chmod 755 "$scratch"
chmod 644 "$scratch/Caddyfile"
docker network create "$name" >/dev/null
docker volume create "$name-logs" >/dev/null
docker run -d --name "$name-caddy" --network "$name" \
    -v "$scratch/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$name-logs:/var/log/caddy" "$image" >/dev/null
docker run -d --name "$name-dashboard" --network "container:$name-caddy" \
    -v "$name-logs:/access-log:ro" -v "$scratch/auth:/control/auth:ro" \
    -e DASHBOARD_AUTH_FILE=/control/auth/auth.json -e DASHBOARD_BOOT_PROBE_TOKEN \
    -e UPDATE_INTERVAL=2 pithead-dashboard:itest >/dev/null
run_driver() {
    docker run --rm -i --network "$1" -v "$name-logs:/access-log:ro" \
        -e DASHBOARD_BOOT_PROBE_TOKEN --entrypoint python pithead-dashboard:itest - "$2" "$3" <"$ROOT/tests/integration/mini-stack/boot-health-proxy.py"
}
run_driver "container:$name-caddy" local 127.0.0.1
docker exec "$name-dashboard" /app/healthcheck.sh >/dev/null
run_driver "$name" external "$name-caddy"
# A real fronting proxy turns an external socket into a loopback connection to Caddy.
docker run -d --name "$name-front" --network "container:$name-caddy" \
    -v "$ROOT/tests/integration/mini-stack/boot-health-front-proxy.py:/fixture.py:ro" \
    --entrypoint python pithead-dashboard:itest /fixture.py >/dev/null
run_driver "$name" proxy "$name-caddy"
run_driver "container:$name-caddy" final 127.0.0.1
docker exec -i -e DASHBOARD_BOOT_PROBE_TOKEN "$name-dashboard" python - <<'PYLOG'
import os
from pathlib import Path
raw = Path("/access-log/access.log").read_text()
capability = os.environ["DASHBOARD_BOOT_PROBE_TOKEN"]
if capability in raw or "X-Pithead-Boot-Probe" in raw:
    raise AssertionError("boot capability leaked into access log")
PYLOG
DASHBOARD_AUTH_HASH_B64=""
printf '%s\n' '{"users":[],"metrics_password_hash":""}' >"$scratch/auth/auth.json"
generate_caddyfile "$scratch/Caddyfile"
docker exec "$name-caddy" caddy reload --config /etc/caddy/Caddyfile >/dev/null
run_driver "container:$name-caddy" unlocked 127.0.0.1
echo '  ✓ rendered Caddy boot marker survives auth and cannot suppress network login failures'

docker rm -f "$name-dashboard" "$name-caddy" >/dev/null
docker volume rm "$name-logs" >/dev/null
docker volume create "$name-logs" >/dev/null
DASHBOARD_AUTH_HASH_B64=$(printf '%s' "$auth_hash" | openssl base64 -A)
generate_caddyfile "$scratch/Caddyfile"
docker run -d --name "$name-caddy" --network "$name" \
    -v "$scratch/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$name-logs:/var/log/caddy" "$image" >/dev/null
docker run -d --name "$name-dashboard" --network "container:$name-caddy" \
    -v "$ROOT/tests/integration/mini-stack/caddy-auth-upstream.py:/fixture.py:ro" \
    --entrypoint python pithead-dashboard:itest /fixture.py >/dev/null
run_driver "$name" old-backend "$name-caddy"
echo '  ✓ real Caddy refuses an upstream without the dashboard auth protocol'
