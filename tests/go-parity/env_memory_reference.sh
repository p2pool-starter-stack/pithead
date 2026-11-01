#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
fixture=$2
platform=$3
memory_limit=$4
memory_ram=$5
memory_huge=$6
memory_log=$7

uname() { printf 'Linux\n'; }
# shellcheck source=/dev/null
source "$root/tests/stack/fixtures/config-2.0.0/render.sh" "$root/pithead" "$fixture" "$platform"
jq --arg limit "$memory_limit" '.tari.mem_limit=$limit' config.json >config.memory.json
mv config.memory.json config.json
awk() {
    case "${1:-}" in
    *MemTotal*)
        printf 'awk:ram\n' >>"$memory_log"
        printf '%s\n' "$memory_ram"
        ;;
    *HugePages_Total*)
        printf 'awk:huge\n' >>"$memory_log"
        printf '%s\n' "$memory_huge"
        ;;
    *) command awk "$@" ;;
    esac
}
sysctl() {
    printf 'sysctl\n' >>"$memory_log"
    return 99
}
render_env
