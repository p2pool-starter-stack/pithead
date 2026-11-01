#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
export PITHEAD_IMPL=bash

# shellcheck source=/dev/null
source <(/usr/bin/sed -n \
    '/^zmq_greeting_ok() {/,/^}/p; /^zmq_ready_is_publisher() {/,/^}/p; /^zmq_endpoint_is_publisher() {/,/^}/p' \
    "$root/lib/pithead/10-node-probe.sh")
declare -F zmq_greeting_ok zmq_ready_is_publisher zmq_endpoint_is_publisher >/dev/null

timeout() {
    [ "$#" -eq 6 ] && [ "$1" = 5 ] && [ "$2" = bash ] && [ "$3" = -c ] || return 99
    # shellcheck disable=SC2016
    local script=$4 opener='exec 3<>/dev/tcp/"$0"/"$1" 2>/dev/null || exit 1' remainder
    remainder=${script#*"$opener"}
    [ "$remainder" != "$script" ] && [[ "$remainder" != *"$opener"* ]] || return 99
    script=${script/"$opener"/': <&3 >&3 || exit 1'}
    "$ZMQ_TIMEOUT" "$1" "$ZMQ_BASH" -c "$script" "$5" "$6"
}

NODE_PROBE_REASON=""
if zmq_endpoint_is_publisher fixture.invalid 18083; then result=0; else result=$?; fi
printf '%s\n%s\n' "$result" "$NODE_PROBE_REASON"
