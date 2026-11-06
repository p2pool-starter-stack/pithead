#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
(
    cd "$scratch"
    source "$ROOT/lib/pithead/12-firstboot-wizard.sh"
    # shellcheck source=lib/pithead/12a-wizard-page.sh
    source "$ROOT/lib/pithead/12a-wizard-page.sh"
    PRESEED_DIR="$scratch/esp"
    PITHEAD_REGISTRY=example
    STACK_VERSION="test"
    runs=0
    mkdir -p data/firstboot
    restore_submission_dir() { printf '%s' "$scratch/restore"; }
    clear_legacy_wizard_snapshots() { :; }
    clear_restore_stages() { :; }
    wizard_clear_restore_state() { :; }
    clear_setup_candidate() { :; }
    installer_mode_available() { return 1; }
    machine_role() { printf coordinator; }
    consume_preseed_restore() { return 2; }
    consume_preseed_config() { return 1; }
    boot_is_removable() { return 1; }
    _console() { :; }
    container_engine() { printf fake_engine; }
    export_build_provenance() { :; }
    stage_wizard_spool() { printf fixture-fingerprint; }
    prepare_wizard_spool() { :; }
    load_baked_images() { :; }
    clear_restore_submission() { :; }
    clear_restore_carry() { :; }
    wizard_clear_submission_transaction() { :; }
    preseed_token() { return 1; }
    wizard_mint_token() {
        local count=0
        [ ! -f mints ] || count=$(cat mints)
        count=$((count + 1))
        printf '%s' "$count" >mints
        printf 'pit-AAAAA%s' "$((count + 1))"
    }
    wizard_host_addresses() { printf 192.0.2.10; }
    reset_slot_restore_good() { :; }
    wizard_announce_setup() { printf '%s %s\n' "$2" "$3" >>announcements; }
    wizard_keep_requested() { [ "$runs" -eq 2 ]; }
    firstboot_consume_rig() { return 2; }
    firstboot_consume_restore() { return 2; }
    firstboot_consume_spool() { return 1; }
    warn() { :; }
    error() {
        printf '%s\n' "$*" >&2
        exit 1
    }
    sleep() { exit 91; }
    fake_engine() {
        case "$1" in
        rm) : ;;
        run)
            runs=$((runs + 1))
            [ "$runs" -le 2 ] || exit 92
            printf '%s\n' "$@" >>engine-args
            ;;
        inspect) printf false ;;
        *) exit 93 ;;
        esac
    }
    firstboot_wizard
    [ "$runs" -eq 2 ]
    [ "$(cat mints)" = 2 ]
    [ "$(cat announcements)" = $'pit-AAAAA2 fixture-fingerprint\npit-AAAAA3 fixture-fingerprint' ]
    [ "$(grep -c '^WIZARD_TOKEN=pit-AAAAA[23]$' engine-args)" = 2 ]
    [ "$(grep -c '^WIZARD_TLS_CERT=/wizard-spool/wizard.crt$' engine-args)" = 2 ]
)
printf 'selftest-wizard-lockout-loop: PASS\n'
