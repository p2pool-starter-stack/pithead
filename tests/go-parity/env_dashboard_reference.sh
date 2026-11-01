#!/usr/bin/env bash
set -Eeuo pipefail

root=$1

# shellcheck source=/dev/null
source "$root/lib/pithead/19a-config-defaults.sh"
config_defaults_json
