#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
work=$2

cd "$work"
export PITHEAD_IMPL="${COMPOSE_PROJECT_PARITY_IMPL:-bash}"
unset PITHEAD_GO_HELPER

warn() { printf '%s\n' "$*" >&2; }

# shellcheck source=/dev/null
source "$root/lib/pithead/19-small-utilities.sh"
# shellcheck source=/dev/null
if [ "${COMPOSE_PROJECT_WITHOUT_GO_HOOK:-0}" != 1 ]; then
    source "$root/lib/pithead/19c-go-compose-project.sh"
fi

if [ "${COMPOSE_PROJECT_NOCASEMATCH:-0}" = 1 ]; then shopt -s nocasematch; fi
if [ -n "${COMPOSE_PROJECT_CAT_RC:-}" ]; then
    cat() {
        printf '%s' "${COMPOSE_PROJECT_CAT_PARTIAL:-}"
        return "$COMPOSE_PROJECT_CAT_RC"
    }
fi
if [ -n "${COMPOSE_PROJECT_GREP_RC:-}" ]; then
    grep() {
        printf '%s' "${COMPOSE_PROJECT_GREP_PARTIAL:-}"
        return "$COMPOSE_PROJECT_GREP_RC"
    }
fi
if [ "${COMPOSE_PROJECT_FORGE_BUILTINS:-0}" = 1 ]; then
    type() {
        printf 'type\n' >>"$COMPOSE_PROJECT_FORGED_BUILTIN_MARKER"
        case "${1:-}:${2:-}" in
        -t:cat | -t:grep) printf 'file' ;;
        -P:cat | -P:grep) builtin command -p -v "$2" ;;
        *) builtin type "$@" ;;
        esac
    }
    command() {
        printf 'command\n' >>"$COMPOSE_PROJECT_FORGED_BUILTIN_MARKER"
        builtin command "$@"
    }
fi
if [ -n "${COMPOSE_PROJECT_HASH_CAT:-}" ]; then builtin hash -p "$COMPOSE_PROJECT_HASH_CAT" cat; fi
if [ -n "${COMPOSE_PROJECT_HASH_GREP:-}" ]; then builtin hash -p "$COMPOSE_PROJECT_HASH_GREP" grep; fi

compose_project_name
