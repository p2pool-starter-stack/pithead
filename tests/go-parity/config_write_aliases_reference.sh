#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
work=$2
operation=$3

cd "$work"
export PITHEAD_CONFIG_FILE=config.json
export PITHEAD_IMPL="${CONFIG_WRITE_ALIASES_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/15-os-update.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/44-control-upgrade-and-lifecycle.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27-defaults-and-config-validation.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27a-config-version.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27l-go-config-version.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27m-go-config-migrations.sh"
# shellcheck disable=SC2034
PITHEAD_DRY_RUN=0

if [ "$operation" = version ]; then mktemp() { printf 'config.json.version.alias'; }; fi

case "$operation" in
workers) migrate_legacy_workers ;;
telegram) migrate_removed_telegram_control ;;
version) stamp_config_version ;;
*) exit 64 ;;
esac
