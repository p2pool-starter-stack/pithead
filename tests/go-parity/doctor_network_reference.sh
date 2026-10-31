#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
directory=$3
export PITHEAD_APPLIANCE=$4
fixture_bind=$5
fixture_port=$6
fixture_env_bind=$7
fixture_env_port=$8
fixture_password=$9
fixture_tls=${10}
fixture_prefix=${11}
export PITHEAD_ENV_FILE="$directory/.env"
export PITHEAD_IMPL=bash
export NO_COLOR=1

# shellcheck source=/dev/null
source "$root/pithead"
cd "$directory"
export STRATUM_BIND=$fixture_bind
export STRATUM_PORT=$fixture_port
env_get() {
    case "$1" in
    STRATUM_BIND) printf '%s' "$fixture_env_bind" ;;
    STRATUM_PORT) printf '%s' "$fixture_env_port" ;;
    PROXY_STRATUM_PASSWORD) printf '%s' "$fixture_password" ;;
    PROXY_STRATUM_TLS) printf '%s' "$fixture_tls" ;;
    NETWORK_PREFIX) printf '%s' "$fixture_prefix" ;;
    esac
}

case "$operation" in
public-ip)
    is_public_ip "$fixture_prefix"
    exit
    ;;
public-ips)
    host_public_ips
    exit
    ;;
port)
    stratum_port_effective
    exit
    ;;
running)
    container_is_running "$fixture_prefix"
    exit
    ;;
mining)
    mining_stack_running
    exit
    ;;
setup)
    check_stratum_exposure setup
    exit
    ;;
esac

rows=$(/usr/bin/mktemp)
trap '/bin/rm -f "$rows"' EXIT
export DR_JSON_FILE="$rows"
case "$operation" in
exposure) check_stratum_exposure doctor >&2 ;;
listening) check_stratum_listening >&2 ;;
tor) check_tor_running >&2 ;;
clearnet) check_tor_clearnet_egress >&2 ;;
*) exit 64 ;;
esac
/bin/cat "$rows"
