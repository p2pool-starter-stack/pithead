#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
if [ -n "${CADDY_ERR_LOG:-}" ]; then
    trap 'printf "err:%s\n" "$?" >>"$CADDY_ERR_LOG"' ERR
fi

# shellcheck source=/dev/null
source "$root/lib/pithead/35c-caddy-go-bind.sh"
# shellcheck source=/dev/null
source "$root/tests/go-parity/caddy_reference.sh" "$@"
