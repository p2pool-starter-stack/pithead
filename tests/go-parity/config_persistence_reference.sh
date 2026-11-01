#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
work=$2
operation=$3
shift 3

cd "$work"
export PITHEAD_CONFIG_FILE=config.json
export PITHEAD_IMPL="${CONFIG_PERSISTENCE_PARITY_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/19a-config-defaults.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/23-setup-and-credentials.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27-defaults-and-config-validation.sh"
# shellcheck source=/dev/null
[ ! -f "$root/lib/pithead/27n-go-config-persistence.sh" ] || source "$root/lib/pithead/27n-go-config-persistence.sh"
# shellcheck disable=SC2034
PITHEAD_DRY_RUN=${CONFIG_PERSISTENCE_DRY_RUN:-0}

config_defaults() {
    printf 'provider:%s:%s\n' "$1" "$2" >>"$CONFIG_PERSISTENCE_CALL_LOG"
    printf '%s' "${CONFIG_PERSISTENCE_DEFAULTS:-{\"tor\":{\"auto_heal\":true},\"dashboard\":{\"control\":{\"enabled\":true}}}}"
    return "${CONFIG_PERSISTENCE_PROVIDER_RC:-0}"
}

case "${CONFIG_PERSISTENCE_FAIL_TOOL:-}" in
cat) cat() { return 1; } ;;
mktemp) mktemp() { return 1; } ;;
mv) mv() { return 1; } ;;
chmod) chmod() { return 1; } ;;
esac
if [ "${CONFIG_PERSISTENCE_FIXED_TMP:-0}" = 1 ]; then mktemp() { printf 'defaults.tmp'; }; fi
if [ "${CONFIG_PERSISTENCE_TRACE_MV:-0}" = 1 ]; then
    mv() {
        mode=$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null)
        printf 'mv-mode:%s\n' "$mode"
        command mv "$@"
    }
fi
if [ "${CONFIG_PERSISTENCE_ERR_TRAP:-0}" = 1 ]; then
    trap 'printf "err:%s\n" "$?"' ERR
fi

case "$operation" in
credentials) persist_node_credentials "$1" "$2" ;;
defaults) apply_appliance_defaults "${1:-}" ;;
read-sites)
    # shellcheck disable=SC2034
    STACK="$root/pithead"
    bad() { printf 'bad:%s:%s\n' "$1" "$2"; }
    # shellcheck source=/dev/null
    source "$root/tests/stack/lib/config-read-sites.sh"
    set +e
    config_read_sites
    extractor_rc=$?
    set -e
    [ "$extractor_rc" -eq 0 ]
    printf 'status:%s\n' "$DRIFT_BAD"
    ;;
*) exit 64 ;;
esac
