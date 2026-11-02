#!/usr/bin/env bash

_stack_native_adapter_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_STACK_NATIVE_REPO_ROOT="$(cd -P "$_stack_native_adapter_dir/../.." && pwd -P)"
: "${STACK_NATIVE_WRAPPER:=$_stack_native_adapter_dir/stack_native_binary.sh}"
: "${STACK_NATIVE_IMPL:=}"
export STACK_NATIVE_WRAPPER STACK_NATIVE_IMPL
unset _stack_native_adapter_dir

_stack_native_hybrid=0
case "${PITHEAD_IMPL:-}" in
bash | python)
    STACK_NATIVE_REFERENCE=1
    export STACK_NATIVE_REFERENCE
    ;;
esac
if [ "${_PITHEAD_GO_HYBRID:-}" = 1 ] && [ -n "${STACK_NATIVE_INVOCATION:-}" ]; then
    _stack_native_hybrid=1
    if ! printf 'fallback\t%s\t%s\tcli\t%s\n' "$STACK_NATIVE_INVOCATION" "${STACK_NATIVE_FRAGMENT:-harness}" "${STACK_NATIVE_CLI_LABEL:-none}" >>"$STACK_NATIVE_LOG"; then
        printf 'stack native trace write failed\n' >&2
        exit 2
    fi
    STACK_NATIVE_FALLBACK=1
    PITHEAD_GO_CONFIG_DOCUMENT_BINARY="$STACK_NATIVE_WRAPPER"
    export STACK_NATIVE_FALLBACK PITHEAD_GO_CONFIG_DOCUMENT_BINARY
    unset STACK_NATIVE_INVOCATION STACK_NATIVE_CLI_LABEL
fi

if [ "$STACK_NATIVE_IMPL" = go ] && [ "$_stack_native_hybrid" -eq 0 ] && [ "${STACK_NATIVE_FALLBACK:-}" != 1 ] && [ "${STACK_NATIVE_REFERENCE:-}" != 1 ]; then
    PITHEAD_IMPL=go
    PITHEAD_GO_BINARY="$STACK_NATIVE_WRAPPER"
    PITHEAD_GO_CONFIG_DOCUMENT_BINARY="$STACK_NATIVE_WRAPPER"
    export PITHEAD_IMPL PITHEAD_GO_BINARY PITHEAD_GO_CONFIG_DOCUMENT_BINARY
fi
unset _stack_native_hybrid

case "$0" in
tests/stack/run.sh | */tests/stack/run.sh) ;;
tests/stack/*.sh | */tests/stack/*.sh)
    STACK_NATIVE_FRAGMENT="${0#tests/stack/}"
    STACK_NATIVE_FRAGMENT="${STACK_NATIVE_FRAGMENT#*/tests/stack/}"
    export STACK_NATIVE_FRAGMENT
    if [ -n "${STACK_NATIVE_LOG:-}" ]; then
        if ! printf 'visit\t%s_%s\t%s\tfragment\tdirect\n' "$$" "${RANDOM:-0}" "$STACK_NATIVE_FRAGMENT" >>"$STACK_NATIVE_LOG"; then
            printf 'stack native trace write failed\n' >&2
            exit 2
        fi
    fi
    ;;
esac

_STACK_NATIVE_ACTIVE=0
_STACK_NATIVE_ACTIVE_FRAGMENT=""
_STACK_NATIVE_ACTIVE_ID=""
_STACK_NATIVE_ACTIVE_LIB=0
_STACK_NATIVE_HAD_FRAGMENT=0
_STACK_NATIVE_PREVIOUS_FRAGMENT=""

_stack_native_resolve_source() {
    local command="$1" here="$2" root="$3" index suffix candidate=""
    shift 3
    if [[ $command =~ ^source[[:space:]]+\"\$HERE/([^\"]+)\" ]]; then
        candidate="$here/${BASH_REMATCH[1]}"
    elif [[ $command =~ ^source[[:space:]]+\"\$ROOT/tests/stack/([^\"]+)\" ]]; then
        candidate="$root/tests/stack/${BASH_REMATCH[1]}"
    elif [[ $command =~ ^source[[:space:]]+\"\$([0-9]+)([^\"]*)\" ]]; then
        index="${BASH_REMATCH[1]}"
        suffix="${BASH_REMATCH[2]}"
        if [ "$index" -gt 0 ] && [ "$index" -le "$#" ]; then
            candidate="${!index}$suffix"
        fi
    elif [[ $command =~ ^source[[:space:]]+\"?([^\"[:space:]]+/tests/stack/[^\"[:space:]]+\.sh)\"? ]]; then
        candidate="${BASH_REMATCH[1]}"
    fi
    case "$candidate" in
    tests/stack/*.sh | */tests/stack/*.sh)
        _STACK_NATIVE_RESOLVED="${candidate#tests/stack/}"
        _STACK_NATIVE_RESOLVED="${_STACK_NATIVE_RESOLVED#*/tests/stack/}"
        ;;
    *) _STACK_NATIVE_RESOLVED="" ;;
    esac
}

_stack_native_debug() {
    local previous_status="$1" command="$2" caller_source="$3" here="" root="$_STACK_NATIVE_REPO_ROOT"
    here="${caller_source%/*}"
    shift 3
    if [ "$_STACK_NATIVE_ACTIVE" -eq 1 ]; then
        if [ -n "$_STACK_NATIVE_ACTIVE_ID" ]; then
            if ! printf 'visit-result\t%s\t%s\tfragment\tsource\t%d\n' "$_STACK_NATIVE_ACTIVE_ID" "$_STACK_NATIVE_ACTIVE_FRAGMENT" "$previous_status" >>"$STACK_NATIVE_LOG"; then
                printf 'stack native trace write failed\n' >&2
                exit 2
            fi
        fi
        if [ "$_STACK_NATIVE_ACTIVE_LIB" -eq 1 ] && [ "$STACK_NATIVE_IMPL" = go ] && [ "${_PITHEAD_GO_HYBRID:-}" != 1 ] && [ "${STACK_NATIVE_FALLBACK:-}" != 1 ] && [ "${STACK_NATIVE_REFERENCE:-}" != 1 ]; then
            PITHEAD_IMPL=go
            PITHEAD_GO_BINARY="$STACK_NATIVE_WRAPPER"
            PITHEAD_GO_CONFIG_DOCUMENT_BINARY="$STACK_NATIVE_WRAPPER"
            export PITHEAD_IMPL PITHEAD_GO_BINARY PITHEAD_GO_CONFIG_DOCUMENT_BINARY
        fi
        if [ "$_STACK_NATIVE_HAD_FRAGMENT" -eq 1 ]; then
            STACK_NATIVE_FRAGMENT="$_STACK_NATIVE_PREVIOUS_FRAGMENT"
            export STACK_NATIVE_FRAGMENT
        else
            unset STACK_NATIVE_FRAGMENT
        fi
        _STACK_NATIVE_ACTIVE=0
        _STACK_NATIVE_ACTIVE_FRAGMENT=""
        _STACK_NATIVE_ACTIVE_ID=""
        _STACK_NATIVE_ACTIVE_LIB=0
    fi
    case "$command" in
    source[[:space:]]*) ;;
    *) return 0 ;;
    esac
    _stack_native_resolve_source "$command" "$here" "$root" "$@"
    [ -n "$_STACK_NATIVE_RESOLVED" ] || return 0
    if [ "${STACK_NATIVE_FRAGMENT+x}" = x ] && [ "$_STACK_NATIVE_RESOLVED" != lib.sh ]; then
        return 0
    fi
    _STACK_NATIVE_ACTIVE=1
    _STACK_NATIVE_ACTIVE_FRAGMENT="$_STACK_NATIVE_RESOLVED"
    _STACK_NATIVE_HAD_FRAGMENT=0
    _STACK_NATIVE_PREVIOUS_FRAGMENT=""
    if [ "${STACK_NATIVE_FRAGMENT+x}" = x ]; then
        _STACK_NATIVE_HAD_FRAGMENT=1
        _STACK_NATIVE_PREVIOUS_FRAGMENT="$STACK_NATIVE_FRAGMENT"
    fi
    if [ "$_STACK_NATIVE_ACTIVE_FRAGMENT" = lib.sh ]; then
        _STACK_NATIVE_ACTIVE_LIB=1
        STACK_NATIVE_FRAGMENT=harness
        export STACK_NATIVE_FRAGMENT
        return 0
    fi
    STACK_NATIVE_FRAGMENT="$_STACK_NATIVE_ACTIVE_FRAGMENT"
    export STACK_NATIVE_FRAGMENT
    if [ -n "${STACK_NATIVE_LOG:-}" ]; then
        _STACK_NATIVE_ACTIVE_ID="$$_${RANDOM:-0}"
        if ! printf 'visit\t%s\t%s\tfragment\tsource\n' "$_STACK_NATIVE_ACTIVE_ID" "$_STACK_NATIVE_ACTIVE_FRAGMENT" >>"$STACK_NATIVE_LOG"; then
            printf 'stack native trace write failed\n' >&2
            exit 2
        fi
    fi
}

trap '_stack_native_debug "$?" "$BASH_COMMAND" "${BASH_SOURCE[0]-}" "$@"' DEBUG
