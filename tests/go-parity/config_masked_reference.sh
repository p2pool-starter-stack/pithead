#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
work=$2
operation=$3

cd "$work"
export PITHEAD_CONFIG_FILE=config.json
export PITHEAD_IMPL="${CONFIG_MASKED_PARITY_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/22a-config-document.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/30-release-fetch-and-masked-config.sh"
# shellcheck source=/dev/null
if [ "${CONFIG_MASKED_SOURCE_ONLY:-0}" != 1 ]; then
    source "$root/lib/pithead/30a-go-masked-config.sh"
fi

warn() { printf 'warn:%s\n' "$*" >>calls; }
render_worker_read_tokens() {
    printf 'worker-read\n' >>calls
    if [ "${CONFIG_MASKED_WORKER_RC:-0}" -ne 0 ]; then
        command rm -f "$1/worker-read-tokens.json"
        return "$CONFIG_MASKED_WORKER_RC"
    fi
    printf '%s\n' '[{"name":"synthetic-worker"}]' >"$1/worker-read-tokens.json"
    command chmod 600 "$1/worker-read-tokens.json"
}

mkdir() {
    printf 'mkdir\n' >>calls
    [ "${CONFIG_MASKED_FAIL_TOOL:-}" != mkdir ] || return 1
    command mkdir "$@"
}
chmod() {
    printf 'chmod:%s\n' "$1" >>calls
    [ "${CONFIG_MASKED_FAIL_TOOL:-}" != chmod ] || return 1
    command chmod "$@"
}
mv() {
    printf 'mv\n' >>calls
    [ "${CONFIG_MASKED_FAIL_TOOL:-}" != mv ] || return 1
    command mv "$@"
}
rm() {
    printf 'rm\n' >>calls
    [ "${CONFIG_MASKED_FAIL_TOOL:-}" != rm ] || return 1
    command rm "$@"
}
cat() {
    [ "${CONFIG_MASKED_FAIL_TOOL:-}" != cat ] || return 1
    command cat "$@"
}
jq() {
    [ "${CONFIG_MASKED_FAIL_TOOL:-}" != jq ] || return 91
    command jq "$@"
}

if [ "${CONFIG_MASKED_ERR_TRAP:-0}" = 1 ]; then
    trap 'printf "err:%s\n" "$?" >>calls' ERR
fi

case "$operation" in
render) render_masked_config control ;;
*) exit 64 ;;
esac
