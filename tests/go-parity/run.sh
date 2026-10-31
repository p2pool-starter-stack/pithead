#!/usr/bin/env bash

set -Eeuo pipefail

parity_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd -P "$parity_dir/../.." && pwd -P)"
export BASH_ENV="$parity_dir/env.sh"
# shellcheck source=tests/go-parity/env.sh
source "$BASH_ENV"
export GOCACHE="$root/.go-cache/build"
export GOMODCACHE="$root/.go-cache/mod"
export GOPATH="$root/.go-cache/gopath"
export UV_CACHE_DIR="$root/.uv-cache"
cd "$root"

if [ "$#" -eq 0 ]; then
    exec make test-stack
fi
exec "$@"
