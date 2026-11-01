#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2

# shellcheck source=/dev/null
source "$root/lib/pithead/19-small-utilities.sh"

case "$operation" in
getters)
    fixture=$3
    # shellcheck source=/dev/null
    source "$root/tests/stack/fixtures/config-2.0.0/render.sh" "$root/pithead" "$fixture" 0
    trap 'printf "getter ERR trap\n" >&2' ERR
    stratum_tls_fingerprint() {
        printf partial-fp
        printf 'fingerprint diagnostic\n' >&2
        return 17
    }
    appliance_tls_dir() {
        printf partial-tls
        printf 'TLS directory diagnostic\n' >&2
        return 23
    }
    render_env
    ;;
quote)
    dotenv_render_value "${ENV_RENDER_VALUE-}"
    ;;
serialize)
    while IFS= read -r -d '' key; do
        IFS= read -r -d '' value || exit 65
        printf '%s=%s\n' "$key" "$(dotenv_render_value "$value")"
    done
    ;;
*) exit 64 ;;
esac
