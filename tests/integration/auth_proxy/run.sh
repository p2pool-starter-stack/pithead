#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scratch=$(mktemp -d -t pithead-auth-proxy.XXXXXX)
run_id="pithead-auth-proxy-$PPID-$$"
network="$run_id-net"
caddy_name="$run_id-caddy"
dashboard_name="$run_id-dashboard"
legacy_name="$run_id-legacy"
data_volume="$run_id-data"
deps_volume="$run_id-deps"
image=${PITHEAD_AUTH_PROXY_IMAGE:-pithead-dashboard:itest}
negative=${1:-}

cleanup() {
    status=$?
    if ((status != 0)); then
        docker logs "$dashboard_name" >&2 2>/dev/null || true
        docker logs "$legacy_name" >&2 2>/dev/null || true
        docker logs "$caddy_name" >&2 2>/dev/null || true
    fi
    if [[ ${PITHEAD_AUTH_PROXY_KEEP:-0} == 1 ]]; then
        printf 'kept auth proxy fixture: %s %s\n' "$run_id" "$scratch" >&2
        return "$status"
    fi
    docker stop "$legacy_name" "$dashboard_name" "$caddy_name" >/dev/null 2>&1 || true
    docker rm "$legacy_name" "$dashboard_name" "$caddy_name" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    docker volume rm "$data_volume" "$deps_volume" >/dev/null 2>&1 || true
    rm -rf "$scratch"
    return "$status"
}
trap cleanup EXIT

docker info >/dev/null
docker image inspect "$image" >/dev/null
bcrypt_version=$(awk '$0 == "name = \"bcrypt\"" { found=1; next } found && $1 == "version" { gsub(/\"/, "", $3); print $3; exit }' "$ROOT/dashboard/uv.lock")
test -n "$bcrypt_version"
caddy_image=$(awk '$0 == "  caddy:" { found=1; next } found && $1 == "image:" { print $2; exit }' "$ROOT/docker-compose.yml")
test -n "$caddy_image"
site_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')
site_host="${run_id}.invalid"

admin_name="admin-$(openssl rand -hex 5)"
viewer_name="viewer-$(openssl rand -hex 5)"
admin_password=$(openssl rand -base64 24 | tr -d '\n')
viewer_password=$(openssl rand -base64 24 | tr -d '\n')
metrics_password=$(openssl rand -base64 24 | tr -d '\n')
hash_password() {
    printf '%s\n' "$1" | docker run --rm -i --log-driver none "$caddy_image" caddy hash-password 2>/dev/null
}
admin_hash=$(hash_password "$admin_password")
viewer_hash=$(hash_password "$viewer_password")
metrics_hash=$(hash_password "$metrics_password")

AUTH_PATH="$scratch/auth.json" ADMIN_NAME="$admin_name" VIEWER_NAME="$viewer_name" \
    ADMIN_HASH="$admin_hash" VIEWER_HASH="$viewer_hash" METRICS_HASH="$metrics_hash" python3 - <<'PY'
import json
import os

payload = {
    "users": [
        {"name": os.environ["ADMIN_NAME"], "role": "admin", "password_hash": os.environ["ADMIN_HASH"]},
        {"name": os.environ["VIEWER_NAME"], "role": "viewer", "password_hash": os.environ["VIEWER_HASH"]},
    ],
    "metrics_password_hash": os.environ["METRICS_HASH"],
}
with open(os.environ["AUTH_PATH"], "w", encoding="utf-8") as stream:
    json.dump(payload, stream)
PY
chmod 755 "$scratch"
chmod 644 "$scratch/auth.json"

# shellcheck source=lib/pithead/35-caddyfile-and-auth-helpers.sh disable=SC2034
source "$ROOT/lib/pithead/35-caddyfile-and-auth-helpers.sh"
is_appliance() { return 1; }
appliance_site_names() { printf '%s' "$site_host"; }
log() { :; }
warn() { printf '%s\n' "$*" >&2; }
error() {
    printf '%s\n' "$*" >&2
    exit 1
}
DASHBOARD_SECURE=true
DASHBOARD_AUTH_ENABLED=true
HOST_PORT="$site_port"
generate_caddyfile "$scratch/Caddyfile"

if [[ "$negative" == "--without-readiness-guard" ]]; then
    awk '
        /forward_auth .* \{/ { skipping=1; next }
        skipping && /^[[:space:]]*}/ { skipping=0; next }
        !skipping { print }
    ' "$scratch/Caddyfile" >"$scratch/Caddyfile.legacy"
    mv "$scratch/Caddyfile.legacy" "$scratch/Caddyfile"
fi
chmod 644 "$scratch/Caddyfile"

docker network create "$network" >/dev/null
docker volume create "$data_volume" >/dev/null
docker volume create "$deps_volume" >/dev/null
docker run --rm --user 0 -e PIP_ROOT_USER_ACTION=ignore -v "$deps_volume:/deps" \
    --entrypoint /usr/local/bin/python "$image" \
    -m pip install --disable-pip-version-check --no-cache-dir --target /deps "bcrypt==$bcrypt_version" >/dev/null
docker run -d --name "$caddy_name" --network "$network" --network-alias "$site_host" \
    -v "$scratch/Caddyfile:/etc/caddy/Caddyfile:ro" "$caddy_image" >/dev/null
docker run -d --name "$dashboard_name" --network "container:$caddy_name" \
    -v "$scratch:/auth:ro" -v "$data_volume:/data" \
    -v "$deps_volume:/auth-deps:ro" -e PYTHONPATH=/auth-deps \
    -v "$ROOT/dashboard/mining_dashboard:/app/mining_dashboard:ro" \
    -e DASHBOARD_AUTH_FILE=/auth/auth.json -e UPDATE_INTERVAL=3600 "$image" >/dev/null

run_probe() {
    docker run --rm --network "$network" \
        -v "$ROOT/tests/integration/auth_proxy/probe.py:/probe.py:ro" \
        -e PROXY_HOST="$site_host" -e SITE_HOST="$site_host" -e SITE_PORT="$site_port" \
        -e ADMIN_NAME="$admin_name" -e ADMIN_PASSWORD="$admin_password" \
        -e VIEWER_NAME="$viewer_name" -e VIEWER_PASSWORD="$viewer_password" \
        -e METRICS_PASSWORD="$metrics_password" --entrypoint python "$image" /probe.py "$1"
}

run_probe authenticated

AUTH_PATH="$scratch/auth.json" python3 - <<'PY'
import json
import os

with open(os.environ["AUTH_PATH"], "w", encoding="utf-8") as stream:
    json.dump({"users": [], "metrics_password_hash": ""}, stream)
PY
run_probe disabled

backend=$(awk '/reverse_proxy / { print $2; exit }' "$scratch/Caddyfile")
backend_host=${backend%:*}
backend_port=${backend##*:}
docker stop "$dashboard_name" >/dev/null
docker rm "$dashboard_name" >/dev/null
docker run -d --name "$legacy_name" --network "container:$caddy_name" \
    -v "$ROOT/tests/integration/auth_proxy/legacy_backend.py:/legacy_backend.py:ro" \
    -e BACKEND_HOST="$backend_host" -e BACKEND_PORT="$backend_port" \
    --entrypoint python "$image" /legacy_backend.py >/dev/null
run_probe stale

printf '%s\n' 'auth proxy integration passed'
