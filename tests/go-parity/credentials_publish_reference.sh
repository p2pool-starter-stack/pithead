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
source "$root/lib/pithead/23-setup-and-credentials.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27n-go-config-persistence.sh"
# shellcheck disable=SC2034
PITHEAD_DRY_RUN=${CONFIG_PERSISTENCE_DRY_RUN:-0}
umask "${CREDENTIALS_PUBLISH_UMASK:-022}"
if [ "${CREDENTIALS_PUBLISH_AFTER_FAILURE:-0}" = 1 ] && [ "$PITHEAD_IMPL" != go ]; then
    mv() {
        command mv "$@"
        command rm -f -- "$CONFIG_FILE"
    }
fi
case "${CONFIG_PERSISTENCE_FAIL_TOOL:-}" in
mv) mv() { return 1; } ;;
chmod) chmod() { return 1; } ;;
cat) cat() { return 1; } ;;
esac
if [ "${CONFIG_PERSISTENCE_ERR_TRAP:-0}" = 1 ]; then
    trap 'printf "err:%s\n" "$?"' ERR
fi
[ "$operation" = credentials ] || exit 64
if [ "${CREDENTIALS_PUBLISH_CONTEXT:-normal}" = conditional ]; then
    result=0
    persist_node_credentials "$1" "$2" || result=$?
    printf 'result:%s\n' "$result"
else
    persist_node_credentials "$1" "$2"
fi
