#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
fixture=$2
platform=$3
stub_cores=$4

# shellcheck source=/dev/null
source "$root/tests/stack/fixtures/config-2.0.0/render.sh" "$root/pithead" "$fixture" "$platform"
nproc() { printf '%s' "$stub_cores"; }
cp "$fixture" config.json
render_env
