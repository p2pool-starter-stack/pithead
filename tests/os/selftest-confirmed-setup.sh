#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/pithead/12-firstboot-wizard.sh
source "$here/../../lib/pithead/12-firstboot-wizard.sh"
# shellcheck source=lib/pithead/38-setup-command.sh
source "$here/../../lib/pithead/38-setup-command.sh"
trace() { printf '%s\n' "$*" >>"$work/trace"; }
error() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}
warn() { :; }
log() { :; }
is_deployed() { [ "$deployed" = yes ]; }
mutation_lock_acquire() { trace lock; }
mutation_lock_release() { trace unlock; }
render_env() { trace render; }
provision_tor() { trace tor; }
prompt_start_stack() {
    trace start
    [ "${PITHEAD_DEFER_LOCAL_MINER:-0}" = 1 ] || provision_local_miner
}
provision_local_miner() { trace miner; }
for stub in check_prerequisites ensure_config_exists ensure_onion_password parse_and_validate_config \
    preflight_resources check_stratum_exposure load_preserved_state resolve_dashboard_host \
    reconcile_appliance_hostname prepare_directories inject_service_configs optimize_kernel \
    generate_caddyfile provision_control_runner provision_egress_check_units \
    provision_lan_guard_check_units render_local_miner_config update_current_symlink \
    announce_dashboard_url; do
    eval "$stub() { :; }"
done
REBOOT_REQUIRED=false deployed=yes
if (PITHEAD_SETUP_AGAIN=1 setup </dev/null) >"$work/direct.log" 2>&1; then
    echo 'headless setup accepted an existing deployment' >&2
    exit 1
fi
grep -q 'Already provisioned' "$work/direct.log"
[ ! -e "$work/trace" ]
deployed=no
setup </dev/null
[ "$(grep -c '^miner$' "$work/trace")" = 1 ] || {
    printf 'FAIL: setup must provision the miner exactly once\n' >&2
    cat "$work/trace" >&2
    exit 1
}
printf 'lock\nrender\ntor\nrender\nunlock\nstart\nminer\n' >"$work/expected"
cmp "$work/expected" "$work/trace"
rm "$work/trace"
PITHEAD_DEFER_LOCAL_MINER=1 setup_confirmed </dev/null
printf 'lock\nrender\ntor\nrender\nunlock\nstart\n' >"$work/expected"
cmp "$work/expected" "$work/trace"
deployed=yes
restore_submission_dir() { echo "$PWD/restore"; }
machine_role() { echo pithead; }
setup_again_mode() { return 0; }
installer_mode_available() { return 1; }
consume_preseed_restore() { return 2; }
boot_is_removable() { return 1; }
container_engine() { echo fixture_engine; }
fixture_engine() { [ "$1" != inspect ] || echo true; }
export_build_provenance() {
    PITHEAD_REGISTRY=fixture
    STACK_VERSION=dev
}
stage_wizard_spool() {
    if [ -f "$1/setup-failed" ]; then
        grep -q 'fixture provisioning failed' "$1/error.txt" || return 1
        cmp config.json "$1/last-attempt.json" || return 1
        trace retry
        return 8
    fi
    mkdir -p "$1"
    echo fingerprint
}
prepare_wizard_spool() { mkdir -p "$1"; }
preseed_token() { echo fixture-token; }
wizard_keep_requested() { [ "$mode" = keep ]; }
wizard_spool_has() {
    [ "$2" = handoff-ack ] && jq -e 'has("username") and has("password") and has("dashboard") and has("stratum")' "$1/handoff.json" >/dev/null
}
firstboot_consume_rig() { return 2; }
firstboot_consume_restore() {
    [ "$mode" = restored ] || return 2
    printf '{}\n' >"$PWD/config.json"
}
firstboot_consume_spool() {
    [ "$mode" != absent ] || return 1
    printf '{}\n' >"$2"
}
remote_node_addresses_allowed() { :; }
preflight_remote_nodes() {
    [ "$mode" != restored ] || {
        trace forbidden-preflight
        return 1
    }
    [ "$mode" != rejected ]
}
bash() { [ "$mode" != invalid ]; }
wizard_prepare_miner_connection() { echo '{}'; }
resolve_default() { printf '%s' "$1"; }
hostname() { echo fixture; }
write_handoff_card() {
    cat >"$1/handoff.json"
    trace handoff
}
machine_role_from_config() { echo pithead; }
record_machine_role() { trace role; }
control_audit_provisioned() { trace audit; }
sleep() {
    case "$mode" in absent | rejected | invalid) exit 7 ;; esac
}
wizard_spool_publish() {
    local spool="$1" name="$2"
    shift 2
    "$@" >"$spool/$name"
}
wizard_spool_read() { cat "$1/$2"; }
wizard_setup_failed() {
    trace failed
    cp config.json config.json.failed
}
for stub in clear_legacy_wizard_snapshots clear_restore_stages wizard_clear_restore_state \
    clear_setup_candidate clear_restore_submission clear_restore_carry \
    wizard_clear_submission_transaction _console load_baked_images wizard_host_addresses \
    reset_slot_restore_good wizard_announce_setup wizard_clear_announcement ensure_appliance_dashboard_password \
    apply_appliance_defaults wizard_publish_retry_config; do
    eval "$stub() { :; }"
done
for mode in keep absent rejected invalid accepted restored failed; do
    mkdir -p "$work/$mode/preseed"
    printf '{}' >"$work/$mode/config.json"
    rm -f "$work/trace"
    rc=0
    (
        cd "$work/$mode"
        PRESEED_DIR="$PWD/preseed"
        if [ "$mode" = failed ]; then
            provision_tor() { error 'fixture provisioning failed'; }
        fi
        firstboot_wizard </dev/null
    ) >"$work/$mode.log" 2>&1 || rc=$?
    case "$mode" in
    keep)
        [ "$rc" -eq 0 ] && [ ! -e "$work/trace" ]
        ;;
    absent | rejected | invalid)
        [ "$rc" -eq 7 ] && [ ! -e "$work/trace" ]
        ;;
    accepted | restored)
        [ "$rc" -eq 0 ] || {
            echo "accepted coordinator resubmit failed: exit $rc" >&2
            exit 1
        }
        printf 'handoff\nrole\nlock\nrender\ntor\nrender\nunlock\nstart\nminer\naudit\n' >"$work/expected"
        cmp "$work/expected" "$work/trace"
        ;;
    failed)
        [ "$rc" -eq 1 ]
        printf 'handoff\nrole\nlock\nrender\nfailed\nretry\n' >"$work/expected"
        cmp "$work/expected" "$work/trace"
        ;;
    esac
done
echo 'confirmed setup: fresh setup, headless refusal, Keep it, submission gates, reprovision and failure propagation passed'
