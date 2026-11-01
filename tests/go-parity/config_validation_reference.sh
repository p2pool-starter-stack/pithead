#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
section=$2
config=$3
export PITHEAD_IMPL="${VALIDATION_PARITY_IMPL:-bash}"
export PITHEAD_CONFIG_FILE="$config"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER
# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/22a-config-document.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27-defaults-and-config-validation.sh"

case "$section" in
workers) validate_worker_endpoints ;;
energy) validate_energy_config ;;
webhooks) validate_webhook_config ;;
controls) validate_config_control_characters ;;
*) exit 64 ;;
esac
