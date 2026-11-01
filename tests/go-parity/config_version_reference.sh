#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
work=$2
operation=$3
shift 3

cd "$work"
export PITHEAD_CONFIG_FILE="$work/config.json"
export PITHEAD_IMPL="${CONFIG_VERSION_PARITY_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/15-os-update.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/44-control-upgrade-and-lifecycle.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27a-config-version.sh"
# shellcheck source=/dev/null
[ ! -f "$root/lib/pithead/27l-go-config-version.sh" ] || source "$root/lib/pithead/27l-go-config-version.sh"
# shellcheck disable=SC2034
PITHEAD_DRY_RUN=${CONFIG_VERSION_DRY_RUN:-0}

case "${CONFIG_VERSION_FAIL_TOOL:-}" in
stat) stat() { return 1; } ;;
mktemp) mktemp() { return 1; } ;;
chmod) chmod() { return 1; } ;;
chown) chown() { return 1; } ;;
mv) mv() { return 1; } ;;
write-target) mktemp() { printf 'blocked'; } ;;
esac

case "$operation" in
code) config_code_version ;;
ok) config_version_ok "$1" ;;
newer) semver_newer "$1" "$2" ;;
stamp) stamp_config_version ;;
restore) restore_config_version_error "$1" ;;
*) exit 64 ;;
esac
