#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/pithead/11a-wizard-spool.sh
source "$root/lib/pithead/11a-wizard-spool.sh"
# shellcheck source=lib/pithead/12-firstboot-wizard.sh
source "$root/lib/pithead/12-firstboot-wizard.sh"
cd "$work"
PRESEED_DIR="$work/esp" PITHEAD_REGISTRY=fixture
mkdir -p "$PRESEED_DIR" "$work/restore" "$work/data/firstboot"
restore_submission_dir() { printf '%s' "$work/restore"; }
clear_legacy_wizard_snapshots() { :; }
clear_restore_stages() { :; }
wizard_clear_restore_state() { :; }
clear_setup_candidate() { :; }
machine_role() { printf pithead; }
installer_mode_available() { return 0; }
container_engine() { printf false; }
export_build_provenance() { STACK_VERSION=fixture; }
stage_wizard_spool() { prepare_wizard_spool "$1"; }
prefill_from_previous_install() {
    wizard_spool_publish "$1" last-attempt.json printf '%s' '{"previous":true}'
}
load_baked_images() { exit 77; }
_console() { :; }
log() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
error() {
    printf '%s\n' "$*" >&2
    exit 1
}
boot() {
    local rc=0
    (firstboot_wizard) >"$work/console" 2>&1 || rc=$?
    [ "$rc" = 77 ] || {
        cat "$work/console"
        return 1
    }
}

printf '{"monero":{"wallet_address":"unchanged-validation-policy"}}' >"$PRESEED_DIR/pithead-config.json"
cp "$PRESEED_DIR/pithead-config.json" "$work/original"
boot
jq -e '.monero.wallet_address == "unchanged-validation-policy"' data/firstboot/last-attempt.json >/dev/null
cmp -s "$PRESEED_DIR/pithead-config.json" "$work/original"
grep -q 'Pre-seeded configuration found' "$work/console"

printf '{malformed' >"$PRESEED_DIR/pithead-config.json"
boot
grep -q 'pre-seeded configuration was rejected' "$work/console" || {
    printf 'FAIL: malformed installer preseed has no console rejection warning\n' >&2
    exit 1
}
test ! -e data/firstboot/last-attempt.json
test ! -e config.json
test "$(cat "$PRESEED_DIR/pithead-config.json")" = '{malformed'

rm "$PRESEED_DIR/pithead-config.json"
boot
jq -e '.previous == true' data/firstboot/last-attempt.json >/dev/null
! grep -q rejected "$work/console" || exit 1
printf 'PASS: installer prefill, malformed rejection, stale-answer clearing and previous-install fallback\n'
