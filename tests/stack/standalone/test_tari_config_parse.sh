#!/usr/bin/env bash
# Feed the rendered Tari config to the pinned minotari_node image (#2341). Tari is the one stack
# service whose image is upstream — no Dockerfile, no `Build image (tari)` CI job — so nothing else
# proves the binary accepts what we render. #2327 added an unknown key under `[common]`; every
# tier-1 to tier-3 check passed and the node exited 101 with a ConfigError on every bench that
# rendered the template. This reproduces that in seconds: no chain data, no network.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

if ! docker info >/dev/null 2>&1; then
    echo "SKIP: docker not available"
    exit 0
fi

TARI_IMAGE=$(grep -oE 'quay\.io/tarilabs/minotari_node:[^[:space:]"]+' "$ROOT/docker-compose.yml" | head -1)
if [ -z "$TARI_IMAGE" ]; then
    echo "FAIL: could not find the pinned minotari_node image in docker-compose.yml" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
echo "CLEARNET_STATE_DIR=$WORK_DIR/clearnet-state" >"$WORK_DIR/.env"

# 00-prelude.sh declares ENV_FILE readonly from PITHEAD_ENV_FILE, so this has to be set first.
export PITHEAD_ENV_FILE="$WORK_DIR/.env"
# shellcheck source=lib/pithead/00-prelude.sh
source "$ROOT/lib/pithead/00-prelude.sh"
# shellcheck source=lib/pithead/19-small-utilities.sh
source "$ROOT/lib/pithead/19-small-utilities.sh"
# shellcheck source=lib/pithead/04-status.sh
source "$ROOT/lib/pithead/04-status.sh"
# shellcheck source=lib/pithead/34-inject-service-configs.sh
source "$ROOT/lib/pithead/34-inject-service-configs.sh"
# shellcheck disable=SC2034  # read by inject_service_configs (34-inject-service-configs.sh), sourced above
TARI_ONION="testonionaddressxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.onion"
# shellcheck disable=SC2034  # same: read by inject_service_configs. Compose default — a no-op substitution.
NETWORK_PREFIX="172.28.0"

cd "$ROOT"
inject_service_configs # renders build/tari/config.toml exactly as `pithead apply`/`setup` would

mkdir -p "$WORK_DIR/node"
CONTAINER="tari-config-parse-check-$$"
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$WORK_DIR"; rm -f "$ROOT/build/tari/config.toml"' EXIT

echo "== config-parse: the pinned minotari_node image accepts the rendered config =="
echo "  (image: $TARI_IMAGE)"
# --network none: the node needs no network to parse config or fail with ConfigError. A config it
# accepts then tries to reach peers and never exits on its own, so this is bounded (#2341): a
# container still running after 20s means the config parsed and startup proceeded past it.

# --user root: production runs 1000:1000 against a data dir pithead has chowned to match; this
# is a config-parse check with no owned data dir, and the image's default non-root user cannot
# write into it — first seen as a log4rs "Permission denied" masquerading as a ConfigError.
docker run -d --network none --name "$CONTAINER" \
    --user root \
    -e WAIT_FOR_TOR=0 \
    -v "$ROOT/build/tari:/var/tari/config:ro" \
    -v "$WORK_DIR/node:/var/tari/node" \
    --entrypoint /var/tari/config/entrypoint.sh \
    "$TARI_IMAGE" --disable-splash-screen --non-interactive >/dev/null

survived=1
for _ in $(seq 1 20); do
    docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true || {
        survived=0
        break
    }
    sleep 1
done

output=$(docker logs "$CONTAINER" 2>&1 || true)

if [ "$survived" -eq 0 ]; then
    echo "$output" >&2
    if grep -q "ConfigError" <<<"$output"; then
        echo "FAIL: minotari_node rejected the rendered config (ConfigError)" >&2
    else
        echo "FAIL: minotari_node exited before the config-parse window elapsed (no ConfigError, unexpected)" >&2
    fi
    exit 1
fi
echo "  ✓ minotari_node accepted the rendered config (still running after the parse window, no ConfigError)"
