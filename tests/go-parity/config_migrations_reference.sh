#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
work=$2
operation=$3

cd "$work"
export PITHEAD_CONFIG_FILE=config.json
export PITHEAD_IMPL="${CONFIG_MIGRATIONS_PARITY_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27-defaults-and-config-validation.sh"
# shellcheck source=/dev/null
[ ! -f "$root/lib/pithead/27m-go-config-migrations.sh" ] || source "$root/lib/pithead/27m-go-config-migrations.sh"
# shellcheck disable=SC2034
PITHEAD_DRY_RUN=${CONFIG_MIGRATIONS_DRY_RUN:-0}

case "${CONFIG_MIGRATIONS_FAIL_TOOL:-}" in
cp) cp() { return 1; } ;;
cat) cat() { return 1; } ;;
stat) stat() { return 1; } ;;
mv) mv() { return 1; } ;;
chmod) chmod() { return 1; } ;;
chown) chown() { return 1; } ;;
esac

case "$operation" in
workers) migrate_legacy_workers ;;
telegram) migrate_removed_telegram_control ;;
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
    printf 'exceptions:%s\n' "${DRIFT_EXCEPTIONS[*]}"
    ;;
*) exit 64 ;;
esac
