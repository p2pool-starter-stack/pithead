#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
if [ -n "${CADDY_ERR_LOG:-}" ]; then
    trap 'printf "err:%s\n" "$?" >>"$CADDY_ERR_LOG"' ERR
fi

# shellcheck source=/dev/null
source "$root/lib/pithead/35c-caddy-go-bind.sh"
eval "$(declare -f _caddy_bind_go | sed '1s/_caddy_bind_go/_caddy_bind_go_native/')"
_caddy_bind_go() {
    local candidate native_rc=0
    candidate=$(_caddy_bind_go_native "$@") || native_rc=$?
    if [ -n "${CADDY_BIND_ACCEPT_LOG:-}" ]; then
        printf '%s\t%s\n' "$native_rc" "$candidate" >>"$CADDY_BIND_ACCEPT_LOG"
    fi
    [ "$native_rc" -eq 0 ] || return "$native_rc"
    printf '%s' "$candidate"
}
# shellcheck source=/dev/null
source "$root/tests/go-parity/caddy_reference.sh" "$@"
