#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
work=$2
operation=$3

cd "$work"
export PITHEAD_IMPL="${PREVIEW_PARITY_IMPL:-bash}"
unset PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/19-small-utilities.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/39-describe-change.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/39a-describe-change-notifications.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/39b-describe-change-exposure.sh"
# shellcheck source=/dev/null
if [ "${PREVIEW_SOURCE_ONLY:-0}" != 1 ] || [ "$PITHEAD_IMPL" = bash ]; then
    source "$root/lib/pithead/39c-go-preview.sh"
fi

config_bool() { printf '%s\n' "${PREVIEW_CONFIG_BOOL:-false}"; }
config_get() { printf '%s\n' "${PREVIEW_XVB_ENABLED:-false}"; }
is_appliance() { [ "${PREVIEW_APPLIANCE:-0}" = 1 ]; }

read_field() { IFS= read -r -d '' "$1"; }

case "$operation" in
describe)
    key=''
    old=''
    new=''
    TARI_MODE=''
    read_field key
    read_field old
    read_field new
    read_field TARI_MODE
    export TARI_MODE
    describe_change "$key" "$old" "$new"
    ;;
env-diff) env_changed_keys old.env new.env ;;
*) exit 64 ;;
esac
