#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
value=$3
export PITHEAD_IMPL=bash

# shellcheck source=/dev/null
source <(/usr/bin/sed -n \
    '/^zmq_greeting_ok() {/,/^}/p; /^zmq_ready_is_publisher() {/,/^}/p; /^zmq_endpoint_is_publisher() {/,/^}/p' \
    "$root/lib/pithead/10-node-probe.sh")
declare -F zmq_greeting_ok zmq_ready_is_publisher zmq_endpoint_is_publisher >/dev/null

case "$operation" in
greeting)
    if zmq_greeting_ok "$value"; then result=0; else result=$?; fi
    printf '%s\n' "$result"
    ;;
ready)
    if zmq_ready_is_publisher "$value"; then result=0; else result=$?; fi
    printf '%s\n' "$result"
    ;;
classify)
    NODE_PROBE_REASON=""
    if zmq_endpoint_is_publisher fixture.invalid 18083; then result=0; else result=$?; fi
    printf '%s\n%s\n' "$result" "$NODE_PROBE_REASON"
    ;;
*) exit 64 ;;
esac
