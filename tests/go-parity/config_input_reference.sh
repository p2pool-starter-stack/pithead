#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
config=$2
trace=$3
scenario=${4:-normal}
export PITHEAD_IMPL="${CONFIG_INPUT_PARITY_IMPL:-bash}"
export PITHEAD_CONFIG_FILE="$config"
unset PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/pithead"

eval "$(declare -f validate_config_document | sed '1s/validate_config_document/reference_validate_config_document/')"
eval "$(declare -f validate_webhook_config | sed '1s/validate_webhook_config/reference_validate_webhook_config/')"
eval "$(declare -f validate_config_control_characters | sed '1s/validate_config_control_characters/reference_validate_config_control_characters/')"

validate_config_document() {
    printf '%s\n' document >>"$trace"
    reference_validate_config_document "$@"
}

validate_webhook_config() {
    printf '%s\n' webhooks >>"$trace"
    reference_validate_webhook_config "$@"
}

validate_config_control_characters() {
    printf '%s\n' controls >>"$trace"
    reference_validate_config_control_characters "$@"
}

is_appliance() {
    printf '%s\n' next >>"$trace"
    exit 71
}

case "$scenario" in
normal) ;;
missing-python | missing-jq | missing-cat)
    PATH=${CONFIG_INPUT_TOOL_PATH:?}
    export PATH
    ;;
producer-failure)
    cat() {
        builtin printf '%s\n' producer >>"$trace"
        builtin return 93
    }
    ;;
*) exit 64 ;;
esac

parse_and_validate_config
