#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
directory=$2
host=$3
port=$4
export CURL_CAP_SMALL=$5
export PITHEAD_IMPL=bash

# shellcheck source=/dev/null
source <(/usr/bin/sed -n '/^monero_rpc_speaks() {/,/^}/p' "$root/lib/pithead/10-node-probe.sh")
declare -F monero_rpc_speaks >/dev/null
NODE_PROBE_REASON=""
if monero_rpc_speaks "$directory/config.json" "$host" "$port"; then
    result=0
else
    result=$?
fi
printf '%s\n%s\n' "$result" "$NODE_PROBE_REASON"
