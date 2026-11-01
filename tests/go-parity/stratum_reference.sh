#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
config=$2
repeat=${3:-1}
export PITHEAD_IMPL="${STRATUM_PARITY_IMPL:-bash}"
export PITHEAD_CONFIG_FILE="$config"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/19-small-utilities.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27b-stratum-endpoint.sh"

STRATUM_BIND=previous-bind
STRATUM_PORT=previous-port
_stratum_finish() {
    local rc=$?
    trap - EXIT
    printf '\0%s\0%s\0' "$STRATUM_BIND" "$STRATUM_PORT"
    exit "$rc"
}
trap _stratum_finish EXIT

for ((index = 0; index < repeat; index++)); do
    parse_stratum_endpoint
done
