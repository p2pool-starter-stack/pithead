#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
work=$2
operation=$3

cd "$work"
export PITHEAD_IMPL="${ENV_READ_PARITY_IMPL:-bash}"
unset PITHEAD_GO_HELPER

error() {
    echo -e "[ERROR] $1" >&2
    exit 1
}

# shellcheck source=/dev/null
source "$root/lib/pithead/19-small-utilities.sh"
# shellcheck source=/dev/null
if [ "${ENV_READ_WITHOUT_GO_HOOK:-0}" != 1 ]; then
    source "$root/lib/pithead/19b-go-env-read.sh"
fi

if [ "${ENV_READ_CAT_RC:-0}" -ne 0 ]; then
    cat() {
        printf '%s' "${ENV_READ_CAT_PARTIAL:-}"
        return "$ENV_READ_CAT_RC"
    }
fi
if [ "${ENV_READ_ERR_TRAP:-0}" = 1 ]; then
    trap 'printf "ERR:%s\n" "$?" >&2' ERR
fi

read_field() { IFS= read -r -d '' "$1"; }

case "$operation" in
decode)
    value=''
    key=''
    read_field value
    read_field key
    dotenv_decode_value "$value" "$key"
    ;;
get) env_get_file "$4" "$5" ;;
*) exit 64 ;;
esac
