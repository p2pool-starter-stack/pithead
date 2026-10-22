#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/pithead/08-uninstall-firstboot.sh
source "$ROOT/lib/pithead/08-uninstall-firstboot.sh"
# shellcheck source=lib/pithead/11a-wizard-spool.sh
source "$ROOT/lib/pithead/11a-wizard-spool.sh"
# shellcheck source=lib/pithead/12-firstboot-wizard.sh
source "$ROOT/lib/pithead/12-firstboot-wizard.sh"
TASK_DIR=$(mktemp -d)
trap 'rm -rf "$TASK_DIR"' EXIT
restore_submission_dir() { printf '%s/restore' "$PWD"; }
clear_legacy_wizard_snapshots() { :; }
clear_restore_stages() { :; }
wizard_clear_restore_state() { :; }
clear_setup_candidate() { :; }
clear_restore_submission() { :; }
clear_restore_carry() { :; }
machine_role() { printf pithead; }
setup_again_mode() { return 1; }
installer_mode_available() { return 0; }
_console() { :; }
container_engine() { printf fixture_engine; }
export_build_provenance() { export PITHEAD_REGISTRY=fixture STACK_VERSION=dev; }
stage_wizard_spool() {
    mkdir -p "$1"
    printf fingerprint
}
prefill_from_previous_install() { return 1; }
load_baked_images() { :; }
preseed_token() { printf pit-fixture; }
wizard_host_addresses() { :; }
wizard_announce_setup() { :; }
wizard_keep_requested() { return 1; }
is_valid_host() { [ "$1" = example.test ]; }
is_valid_port() { [ "$1" = 3333 ]; }
timeout() { :; }
log() { :; }
warn() { :; }
error() {
    printf '%s\n' "$*" >&2
    exit 70
}
sleep() { exit 73; }
firstboot_consume_restore() { return 2; }
firstboot_consume_spool() { exit 72; }
rig_coordinator_ip() { printf 192.0.2.1; }
rig_access_token() {
    jq '.access_token = "0123456789abcdef0123456789abcdef"' rig.json >token.json
    mv token.json rig.json
    printf 0123456789abcdef0123456789abcdef
}
fixture_engine() {
    [ "$1" = run ] || return 0
    printf 'vda\tkeep' >data/firstboot/install-request
    case "$case_name" in
    rig | rig-no-ack | role-only) printf rig >data/firstboot/role ;;
    dangling-role) ln -s "$PWD/missing" data/firstboot/role ;;
    directory-role) mkdir data/firstboot/role ;;
    fifo-role) mkfifo data/firstboot/role ;;
    oversize-role) truncate -s 1048577 data/firstboot/role ;;
    unknown-role) printf unknown >data/firstboot/role ;;
    esac
    case "$case_name" in
    rig | rig-no-ack | request-only)
        printf '{"pool":"example.test:3333","worker":"fixture-rig"}' >data/firstboot/rig-request.json
        ;;
    dangling-request) ln -s "$PWD/missing" data/firstboot/rig-request.json ;;
    esac
    touch data/firstboot/submission-staging data/firstboot/submission-active
}
write_handoff_card() {
    cat >card.json
    printf 'card\n' >>trace
    [ "$case_name" = rig-no-ack ] || touch data/firstboot/handoff-ack
}
wizard_install_begin() { :; }
mount() { :; }
install() {
    [ "$*" = "-m 600 $PWD/rig.json /boot/efi/pithead-rig.json" ] || return 1
    command install -m 600 "$PWD/rig.json" "$PRESEED_DIR/staged.json"
}
rm() {
    local value args=()
    for value in "$@"; do
        [ "$value" != /boot/efi/pithead-rig.json ] || value="$PRESEED_DIR/staged.json"
        args+=("$value")
    done
    command rm "${args[@]}"
}
consume_install_request() {
    printf 'install\n' >>trace
    if [ "$case_name" != bare-keep ]; then
        jq -e '.role == "rig" and .worker == "fixture-rig" and .token == "0123456789abcdef0123456789abcdef"' card.json >/dev/null || return 1
        jq -e '.access_token == "0123456789abcdef0123456789abcdef"' "$PRESEED_DIR/staged.json" >/dev/null || return 1
    fi
}
wizard_install_failed_page() { exit 74; }
wizard_install_finish() { printf 'finish\n' >>trace; }
for case_name in bare-keep rig request-only rig-no-ack role-only dangling-request dangling-role directory-role fifo-role oversize-role unknown-role; do
    mkdir -p "$TASK_DIR/$case_name/preseed"
    result=0
    (
        cd "$TASK_DIR/$case_name"
        export PRESEED_DIR="$PWD/preseed"
        firstboot_wizard
    ) >"$TASK_DIR/$case_name/output" 2>&1 || result=$?
    trace=$(cat "$TASK_DIR/$case_name/trace" 2>/dev/null || true)
    case "$case_name" in
    bare-keep)
        expected=$'install\nfinish'
        expected_rc=0
        ;;
    rig | request-only)
        expected=$'card\ninstall\nfinish'
        expected_rc=0
        ;;
    rig-no-ack)
        expected=card
        expected_rc=73
        ;;
    role-only | dangling-role | directory-role | fifo-role | oversize-role | unknown-role)
        expected=""
        expected_rc=72
        ;;
    dangling-request)
        expected=""
        expected_rc=73
        ;;
    esac
    if [ "$result" -ne "$expected_rc" ] || [ "$trace" != "$expected" ]; then
        printf '%s: expected rc=%s trace=<%s>, got rc=%s trace=<%s>\n' "$case_name" "$expected_rc" "$expected" "$result" "$trace" >&2
        cat "$TASK_DIR/$case_name/output" >&2
        exit 1
    fi
done
printf 'rig installer dispatch self-test: PASS\n'
