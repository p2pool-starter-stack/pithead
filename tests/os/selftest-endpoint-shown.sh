#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/preview-endpoint.sh
source "$HERE/preview-endpoint.sh"

shown='{"preview_values":[{"key":"monero.remote.host","new":"10.0.0.5"},{"key":"tari.remote.host","new":"node.lan"}]}'
monero_only='{"preview_values":[{"key":"monero.remote.host","new":"10.0.0.5"}]}'
local_live='{"monero":{"mode":"local"},"tari":{"mode":"local"}}'
same_live='{"monero":{"mode":"local"},"tari":{"mode":"remote","remote":{"host":"node.lan","grpc_port":18142}}}'
other_live='{"monero":{"mode":"local"},"tari":{"mode":"remote","remote":{"host":"other.lan","grpc_port":18142}}}'
retained_live='{"monero":{"mode":"local"},"tari":{"mode":"local","remote":{"host":"node.lan","grpc_port":18142}}}'
to_remote='{"preview_values":[{"key":"monero.remote.host","new":"10.0.0.5"},{"key":"tari.mode","new":"remote"}]}'

endpoint_shown "$shown" "$local_live" tari node.lan
endpoint_shown "$shown" "$local_live" monero 10.0.0.5
endpoint_shown "$monero_only" "$same_live" tari node.lan
endpoint_shown "$to_remote" "$retained_live" tari node.lan
hidden() {
    if endpoint_shown "$@"; then
        echo "selftest-endpoint-shown: $3 $4 counted as shown" >&2
        exit 1
    fi
}
hidden "$monero_only" "$retained_live" tari node.lan
hidden "$to_remote" "$retained_live" tari other.lan
hidden "$monero_only" "$local_live" tari node.lan
hidden "$monero_only" "$other_live" tari node.lan
hidden "$shown" "$local_live" tari other.lan
echo "selftest-endpoint-shown: a changed endpoint must be in the preview; an unchanged live one counts as shown"
