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

TARI_IMAGE=$(grep -oE 'ghcr\.io/tari-project/minotari_node:[^[:space:]"]+' "$ROOT/docker-compose.yml" | head -1)
if [ -z "$TARI_IMAGE" ]; then
    echo "FAIL: could not find the pinned minotari_node image in docker-compose.yml" >&2
    exit 1
fi

# tests/stack/lib.sh builds $SANDBOX through mk_tmpdir (#1705's sandbox constructor, refusing
# closed rather than falling back to the caller's cwd) and arms its own cleanup trap on it; reuse
# that dir as WORK_DIR instead of a second mktemp -d, and fold its cleanup into the trap below
# (setting a new EXIT trap replaces lib.sh's, so this one has to cover $SANDBOX itself too).
# shellcheck source=tests/stack/lib.sh
source "$ROOT/tests/stack/lib.sh"
WORK_DIR="$SANDBOX"
CONTAINER="tari-config-parse-check-$$"
CALIBRATION="$CONTAINER-libtor"
# rm -rf can leave root-owned files behind (the container ran --user root against $WORK_DIR/node)
# and exit non-zero on them — `|| true` so cleanup never flips an otherwise-passing run to red.
trap 'docker rm -f "$CONTAINER" "$CALIBRATION" >/dev/null 2>&1 || true; rm -rf "$WORK_DIR" 2>/dev/null || true; rm -f "$ROOT/build/tari/config.toml"' EXIT
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
# A syntactically valid v3 onion (56-char base32 + .onion, the same fixture value used in
# tests/stack/control/test-control-diagnostics.sh): minotari_node validates public_addresses as a
# real multiaddr, so a placeholder that isn't shaped like one fails with its own ConfigError
# ("invalid multiaddr") before the check ever gets to what it's actually testing.
# shellcheck disable=SC2034  # read by inject_service_configs (34-inject-service-configs.sh), sourced above
TARI_ONION="abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion"
# shellcheck disable=SC2034  # same: read by inject_service_configs. Compose default — a no-op substitution.
NETWORK_PREFIX="172.28.0"

cd "$ROOT"
inject_service_configs # renders build/tari/config.toml exactly as `pithead apply`/`setup` would
mkdir -p "$WORK_DIR/node"

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

# #2653: the image is built with the `libtor` feature and `base_node.use_libtor` defaults to true, so
# under a Tor hidden-service transport the node starts its own Tor, which dials Tor relays straight
# from the tari container instead of through the stack's tor. That Tor keeps its data under
# <base_path>/libtor, created before the node starts networking.
if [ -e "$WORK_DIR/node/libtor" ]; then
    echo "$output" >&2
    echo "FAIL: minotari_node started its in-process Tor (<base_path>/libtor exists) (#2653)" >&2
    exit 1
fi
echo "  ✓ minotari_node started no in-process Tor (no <base_path>/libtor) (#2653)"

# Calibration: the same image on develop's pre-#2653 transport (`tor`, use_libtor left at its
# default) must create <base_path>/libtor, or the absence above proves nothing. If a future image
# drops the libtor feature this fails, and use_libtor = false can go with it.
mkdir -p "$WORK_DIR/calibration-config" "$WORK_DIR/calibration-node"
cp -p "$ROOT/build/tari/entrypoint.sh" "$WORK_DIR/calibration-config/"
sed -e 's/^type = "socks5"/type = "tor"/' -e '/^use_libtor = /d' "$ROOT/build/tari/config.toml" \
    >"$WORK_DIR/calibration-config/config.toml"
docker run -d --network none --name "$CALIBRATION" --user root -e WAIT_FOR_TOR=0 \
    -v "$WORK_DIR/calibration-config:/var/tari/config:ro" \
    -v "$WORK_DIR/calibration-node:/var/tari/node" \
    --entrypoint /var/tari/config/entrypoint.sh \
    "$TARI_IMAGE" --disable-splash-screen --non-interactive >/dev/null
for _ in $(seq 1 20); do
    [ -e "$WORK_DIR/calibration-node/libtor" ] && break
    sleep 1
done
if [ ! -e "$WORK_DIR/calibration-node/libtor" ]; then
    docker logs "$CALIBRATION" >&2 2>&1 || true
    echo "FAIL: calibration: a Tor transport with use_libtor at its default created no <base_path>/libtor" >&2
    exit 1
fi
echo "  ✓ calibration: the same image on a Tor transport with use_libtor at its default starts libtor"
