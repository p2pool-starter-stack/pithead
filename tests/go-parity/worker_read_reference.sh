#!/usr/bin/env bash
# shellcheck disable=SC2329
set -Eeuo pipefail

root=$1
work=$2
operation=$3

cd "$work"
export PITHEAD_CONFIG_FILE=config.json
export PITHEAD_IMPL="${WORKER_READ_PARITY_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/30-release-fetch-and-masked-config.sh"
# shellcheck source=/dev/null
if [ "${WORKER_READ_SOURCE_ONLY:-0}" != 1 ]; then
    source "$root/lib/pithead/30b-go-worker-read.sh"
fi
# shellcheck source=/dev/null
source "$root/lib/pithead/35-caddyfile-and-auth-helpers.sh"

warn() { printf 'warn:%s\n' "$*" >&2; }

chown() {
    printf 'chown:%s\n' "$*" >>owner.log
    [ "${WORKER_READ_OWNER:-direct}" != direct ] || return 0
    return 1
}
sudo() {
    printf 'sudo:%s\n' "$*" >>owner.log
    [ "${WORKER_READ_OWNER:-direct}" = fallback ]
}
cat() {
    [ "${WORKER_READ_FAIL_TOOL:-}" != cat ] || return 91
    command cat "$@"
}
mktemp() {
    local count=1
    [ ! -e .mktemp-count ] || count=2
    : >.mktemp-count
    case "${WORKER_READ_ALIAS:-}" in
    project)
        if [ "$count" -eq 1 ]; then
            printf '%s\n' "$work/masked/.alias-rows"
            return
        fi
        ;;
    slurp)
        if [ "$count" -eq 1 ]; then
            printf '%s\n' "$work/masked/.alias-rows"
        else
            printf '%s\n' "$work/masked/.alias-tmp"
        fi
        return
        ;;
    esac
    if [ "${WORKER_READ_FAIL_TOOL:-}" = "mktemp-$count" ]; then return 91; fi
    command mktemp "$@"
}
chmod() {
    local count=1
    [ ! -e .chmod-count ] || count=2
    : >.chmod-count
    if [ "${WORKER_READ_FAIL_TOOL:-}" = "chmod-$count" ]; then return 91; fi
    command chmod "$@"
}
mv() {
    [ "${WORKER_READ_FAIL_TOOL:-}" != mv ] || return 91
    command mv "$@"
}
jq() {
    [ "${WORKER_READ_FAIL_TOOL:-}" != jq ] || return 91
    command jq "$@"
}
if [ "${WORKER_READ_HMAC_FAIL:-0}" = 1 ]; then
    hmac_sha256_hex() {
        : >hmac-called
        return 1
    }
fi
if [ "${WORKER_READ_OPENSSL_FAIL:-0}" = 1 ]; then
    openssl() {
        if [ "$*" = "dgst -sha256 -binary" ] && [ ! -e openssl-failed ]; then
            : >openssl-failed
            return 1
        fi
        command openssl "$@"
    }
fi

case "$operation" in
render)
    mkdir -p masked
    set +e
    render_worker_read_tokens masked
    render_rc=$?
    set -e
    exit "$render_rc"
    ;;
*) exit 64 ;;
esac
