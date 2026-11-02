#!/usr/bin/env bash
set -uo pipefail

if [ -z "${STACK_NATIVE_BINARY:-}" ] || [ -z "${STACK_NATIVE_LOG:-}" ]; then
    printf 'STACK_NATIVE_BINARY and STACK_NATIVE_LOG are required\n' >&2
    exit 2
fi

_stack_native_fragment="${STACK_NATIVE_FRAGMENT:-harness}"
_stack_native_helper="${PITHEAD_GO_HELPER:-}"
_stack_native_id="$$_${RANDOM:-0}"
if [ -n "$_stack_native_helper" ]; then
    _stack_native_kind=helper
    _stack_native_label="$_stack_native_helper"
else
    _stack_native_kind=cli
    _stack_native_label="${1:-none}"
fi
if ! printf 'dispatch\t%s\t%s\t%s\t%s\n' "$_stack_native_id" "$_stack_native_fragment" "$_stack_native_kind" "$_stack_native_label" >>"$STACK_NATIVE_LOG"; then
    printf 'stack native trace write failed\n' >&2
    exit 2
fi

if [ "$_stack_native_kind" = cli ] && [ -n "${PITHEAD_GO_REFERENCE:-}" ]; then
    STACK_NATIVE_INVOCATION="$_stack_native_id"
    STACK_NATIVE_CLI_LABEL="$_stack_native_label"
    export STACK_NATIVE_INVOCATION STACK_NATIVE_CLI_LABEL
fi

"$STACK_NATIVE_BINARY" "$@"
_stack_native_rc=$?
if ! printf 'result\t%s\t%s\t%s\t%s\t%d\n' "$_stack_native_id" "$_stack_native_fragment" "$_stack_native_kind" "$_stack_native_label" "$_stack_native_rc" >>"$STACK_NATIVE_LOG"; then
    printf 'stack native trace write failed\n' >&2
    exit 2
fi
exit "$_stack_native_rc"
