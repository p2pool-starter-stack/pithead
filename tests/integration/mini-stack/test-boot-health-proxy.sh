#!/usr/bin/env bash
# Real rendered Caddy + dashboard: boot 401s are marked, network forgeries still count.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/pithead-boot-proxy.XXXXXX")
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
DASHBOARD_SECURE=false HOST_PORT=8080 DASHBOARD_AUTH_USER=admin
export DASHBOARD_AUTH_HASH_B64
DASHBOARD_AUTH_HASH_B64=$(printf '%s\n' fixture-password | docker run --rm -i "$image" caddy hash-password | openssl base64 -A)
generate_caddyfile "$scratch/Caddyfile"
chmod 755 "$scratch"
chmod 644 "$scratch/Caddyfile"
docker network create "$name" >/dev/null
docker volume create "$name-logs" >/dev/null
docker run -d --name "$name-caddy" --network "$name" \
    -v "$scratch/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$name-logs:/var/log/caddy" "$image" >/dev/null
docker run -d --name "$name-dashboard" --network "container:$name-caddy" \
    -v "$name-logs:/access-log:ro" -e UPDATE_INTERVAL=2 pithead-dashboard:itest >/dev/null
# The driver runs once on the loopback side, once across the bridge as an untrusted client.
run_driver() {
    docker run --rm -i --network "$1" -e DASHBOARD_AUTH_HASH_B64 --entrypoint python pithead-dashboard:itest - "$2" "$3" <"$ROOT/tests/integration/mini-stack/boot-health-proxy.py"
}
run_driver "container:$name-caddy" local 127.0.0.1
run_driver "$name" external "$name-caddy"
# A real fronting proxy turns an external socket into a loopback connection to Caddy.
docker run -d --name "$name-front" --network "container:$name-caddy" \
    -v "$ROOT/tests/integration/mini-stack/boot-health-front-proxy.py:/fixture.py:ro" \
    --entrypoint python pithead-dashboard:itest /fixture.py >/dev/null
run_driver "$name" proxy "$name-caddy"
run_driver "container:$name-caddy" final 127.0.0.1
docker exec -i -e DASHBOARD_AUTH_HASH_B64 "$name-dashboard" python - <<'PYLOG'
import hashlib
import os
from pathlib import Path
raw = Path("/access-log/access.log").read_text()
capability = hashlib.sha256(("pithead-boot-health-v1:" + os.environ["DASHBOARD_AUTH_HASH_B64"]).encode()).hexdigest()
if capability in raw or "X-Pithead-Boot-Probe" in raw:
    raise AssertionError("boot capability leaked into access log")
PYLOG
# Authentication disabled must still prove a real nonempty dashboard page after rewriting.
DASHBOARD_AUTH_HASH_B64=""
generate_caddyfile "$scratch/Caddyfile"
docker exec "$name-caddy" caddy reload --config /etc/caddy/Caddyfile >/dev/null
run_driver "container:$name-caddy" unlocked 127.0.0.1
echo '  ✓ rendered Caddy boot marker survives auth and cannot suppress network login failures'
