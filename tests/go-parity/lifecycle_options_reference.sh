#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
values=$3
export PITHEAD_IMPL="${LIFECYCLE_OPTIONS_IMPL:-bash}"
export NO_COLOR=1
unset PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/pithead"
if [ "${LIFECYCLE_OPTIONS_WITHOUT_HOOK:-0}" = 1 ]; then unset -f _parse_lifecycle_options_go; fi
if [ "${LIFECYCLE_OPTIONS_TRACE_NATIVE:-0}" = 1 ]; then
    eval "$(declare -f _parse_lifecycle_options_go | sed '1s/_parse_lifecycle_options_go/_options_native_reference/')"
    _parse_lifecycle_options_go() {
        local native_status=0
        _options_native_reference "$@" || native_status=$?
        printf '%s:%s\n' "$1" "$native_status" >>"$LIFECYCLE_OPTIONS_NATIVE"
        return "$native_status"
    }
fi

arguments=()
while IFS= read -r -d '' value; do arguments+=("$value"); done <"$values"
assume_yes=seed-yes dry_run=seed-dry porcelain=seed-porcelain arg=seed-arg

_options_stop() {
    printf '%s\n' "$1" >>"$LIFECYCLE_OPTIONS_CALLS"
    exit 71
}
export_build_provenance() { printf 'provenance\n' >>"$LIFECYCLE_OPTIONS_CALLS"; }
require_env() { _options_stop env; }
require_deployed() {
    printf 'deployed\n' >>"$LIFECYCLE_OPTIONS_CALLS"
    if [ "${LIFECYCLE_OPTIONS_FAIL_DEPLOYED:-0}" = 1 ]; then error 'fixture is not deployed'; fi
}
render_derived() { _options_stop render; }
stack_up() { _options_stop up; }
stack_down() { _options_stop down; }
mutation_lock_acquire() { _options_stop "lock:$1"; }
show_help() { printf 'fixture help\n'; }
run_chain() {
    printf 'chain\n' >>"$LIFECYCLE_OPTIONS_CALLS"
    exit 72
}
_options_finish() {
    local rc=$?
    trap - EXIT
    printf '%s\0%s\0%s\0%s\0' "$assume_yes" "$dry_run" "$porcelain" "${arg-__unset__}" >"$LIFECYCLE_OPTIONS_STATE"
    exit "$rc"
}
trap _options_finish EXIT

case "$operation" in
main) main "${arguments[@]}" ;;
reject) _reject_options "${arguments[@]}" ;;
*) exit 64 ;;
esac
