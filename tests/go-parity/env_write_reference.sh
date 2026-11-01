#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

root=$1
block=$2
export PITHEAD_IMPL="${ENV_WRITE_IMPL:-bash}"
unset PITHEAD_GO_HELPER
# shellcheck source=/dev/null
source "$root/lib/pithead/33f-go-env-write.sh"
# shellcheck source=/dev/null
source "$block"
IFS= read -r -d '' target
IFS= read -r -d '' native_env
_write_event() { printf '%s\n' "$1" >>"$ENV_WRITE_CALLS"; }
chmod() {
    _write_event chmod
    [ "${ENV_WRITE_SHIM:-}" != chmod-fail ] || return 23
    command chmod "$@"
}
case "${ENV_WRITE_SHIM:-}" in
cat | cat-fail)
    cat() {
        _write_event cat
        if [ "$ENV_WRITE_SHIM" = cat-fail ]; then
            printf partial
            return 19
        fi
        command cat "$@"
    }
    ;;
esac
if [ "${ENV_WRITE_WITHOUT_HOOK:-0}" = 1 ]; then
    unset -f _write_env_go
else
    eval "$(declare -f _write_env_go | sed '1s/_write_env_go/_write_native_reference/')"
    _write_env_go() {
        local status=0
        _write_native_reference "$@" || status=$?
        printf '%s\n' "$status" >>"$ENV_WRITE_NATIVE"
        return "$status"
    }
fi
trap 'printf "ERR:%s\n" "$?" >&2' ERR
umask "${ENV_WRITE_UMASK:-022}"
publish_case
