#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/wizard-startup-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
cat >"$work/engine" <<'ENGINE'
#!/usr/bin/env bash
printf '%s\n' "$1" >>calls
case "$1" in
run)
    [ "$(grep -c '^run$' calls)" -le 2 ] || exit 1
    touch running
    ;;
rm) rm -f running ;;
inspect)
    if [ "$mode" = retry ]; then printf '{}\n' >config.json; fi
    printf 'false\n'
    ;;
esac
ENGINE
chmod +x "$work/engine"
run_case() (
    export mode="$1"
    mkdir "$work/$mode"
    cd "$work/$mode"
    source "$ROOT/pithead"
    PRESEED_DIR="$PWD/preseed"
    mkdir -p "$PRESEED_DIR" restore data/firstboot
    restore_submission_dir() { printf '%s/restore' "$PWD"; }
    clear_legacy_wizard_snapshots() { :; }
    clear_restore_stages() { :; }
    wizard_clear_restore_state() { :; }
    clear_setup_candidate() { :; }
    clear_restore_submission() { :; }
    clear_restore_carry() { :; }
    machine_role() { printf pithead; }
    setup_again_mode() { [ "$mode" = kept ]; }
    installer_mode_available() { [ "$mode" = installer ]; }
    boot_is_removable() { return 1; }
    consume_preseed_restore() { return 2; }
    consume_preseed_config() { return 1; }
    _console() { :; }
    container_engine() { printf '%s/engine' "$work"; }
    export_build_provenance() { :; }
    stage_wizard_spool() { :; }
    prepare_wizard_spool() { mkdir -p "$1"; }
    prefill_from_previous_install() { return 1; }
    load_baked_images() {
        case "$mode" in startup | installer) printf '{}\n' >config.json ;; esac
    }
    wizard_clear_submission_transaction() { :; }
    preseed_token() {
        [ "$mode" != round ] || printf '{}\n' >config.json
        return 1
    }
    wizard_mint_token() { printf token; }
    wizard_host_addresses() { printf '192.0.2.1'; }
    reset_slot_restore_good() { :; }
    wizard_announce_setup() { :; }
    wizard_keep_requested() { return 1; }
    wizard_submission_ready() { return 1; }
    firstboot_consume_rig() { return 2; }
    firstboot_consume_restore() { return 2; }
    firstboot_consume_spool() { return 1; }
    setup() {
        printf 'unexpected setup\n' >&2
        exit 97
    }
    sleep() { :; }
    [ "$mode" != kept ] || printf '{}\n' >config.json
    PITHEAD_REGISTRY=fixture STACK_VERSION=dev firstboot_wizard
)
failures=0
for mode in startup round retry kept installer; do
    rc=0
    run_case "$mode" >"$work/$mode.log" 2>&1 || rc=$?
    runs=$(grep -c '^run$' "$work/$mode/calls")
    case "$mode" in
    startup | round) expected_rc=0 expected_runs=1 ;;
    *) expected_rc=1 expected_runs=3 ;;
    esac
    if [ "$rc" = "$expected_rc" ] && [ "$runs" = "$expected_runs" ] &&
        [ ! -e "$work/$mode/running" ] && [ -f "$work/$mode/config.json" ]; then
        printf 'PASS: wizard startup %s\n' "$mode"
    else
        printf 'FAIL: wizard startup %s (exit %s, runs %s)\n' "$mode" "$rc" "$runs"
        cat "$work/$mode.log"
        failures=$((failures + 1))
    fi
done
[ "$failures" -eq 0 ]
