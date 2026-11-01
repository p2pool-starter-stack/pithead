#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
if [ "${CADDY_AUTH_WITHOUT_GO_HOOK:-0}" != 1 ]; then
    # shellcheck source=/dev/null
    source "$root/lib/pithead/35b-caddy-go-auth.sh"
fi
# shellcheck source=/dev/null
source "$root/tests/go-parity/caddy_reference.sh" "$@"
