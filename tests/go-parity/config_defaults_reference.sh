#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
fixture_platform=$3
CONFIG_FILE=$4
fixture_table=$5
mode=$6
path=$7
export PITHEAD_IMPL="${DEFAULTS_PARITY_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER
# shellcheck source=/dev/null
source "$root/lib/pithead/19a-config-defaults.sh"
config_platform() { printf '%s' "$fixture_platform"; }
config_defaults_json() { /bin/cat "$fixture_table"; }
case "$operation" in
defaults) config_defaults "$mode" "$fixture_platform" ;;
default) default_of "$path" "$mode" ;;
install) new_install_defaults ;;
get) config_get "$path" "$CONFIG_FILE" ;;
*) exit 64 ;;
esac
