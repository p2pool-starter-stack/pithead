#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:?set TMPDIR or RUNNER_TEMP}}"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:?}/image-convergence.XXXXXX")
trap 'rm -rf "$T"' EXIT
source "$ROOT/lib/pithead/01-lifecycle.sh"
source "$ROOT/lib/pithead/03-release-verify.sh"
source "$ROOT/lib/pithead/11-baked-images.sh"
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
mutation_lock_acquire() { :; }
mutation_lock_release() { :; }
validate_config_document() { :; }
log() { :; }
warn() { :; }
_console() { :; }
error() {
    echo "$*" >&2
    exit 1
}
warn_missing_data_dirs() { :; }
migrate_compose_project() { :; }
apply_tor_egress_firewall() { :; }
provision_egress_check_units() { :; }
provision_lan_guard_check_units() { :; }
verify_release_images() { :; }
print_clearnet_banner() { :; }
announce_dashboard_url() { :; }
print_first_run_epilogue() { :; }
repair_broken_image_store() { :; }
container_engine() { echo docker; }
is_appliance() { [ "$CASE" != diy ]; }
env_get() { echo dashboard-data; }
rearm_sync_gate_marker() { echo rearm >>calls; }
REVENUE_CHAIN_CONTAINERS='monerod'
docker() {
    case "$*" in
    'load -i '*) cat "$3" >declared ;;
    'compose config --format json')
        [ "$CASE" != config-failure ] || return 1
        printf '%s\n' '{"services":{"dashboard":{"image":"dashboard:release"},"tor":{"image":"tor:release"},"monerod":{"image":"monero:release"}}}'
        ;;
    'compose config --services') printf 'dashboard\ntor\nmonerod\n' ;;
    'compose ps -a -q dashboard')
        [ "$CASE" != missing-container ] || return 0
        echo dashboard
        ;;
    'compose ps -a -q tor') echo tor ;;
    'compose ps -a -q monerod')
        [ "${PITHEAD_HOLD_CHAIN:-0}" != 1 ] || return 1
        echo monerod
        ;;
    'image inspect --format {{.Id}} dashboard:release')
        [ "$CASE" != empty-declared ] || return 0
        cat declared
        ;;
    'image inspect --format {{.Id}} tor:release') echo tor-image ;;
    'image inspect --format {{.Id}} monero:release') echo monero-image ;;
    'inspect --format {{.Image}} dashboard')
        [ "$CASE" != inspect-failure ] || return 1
        [ "$CASE" != empty-running ] || return 0
        cat running
        ;;
    'inspect --format {{.Image}} tor') echo tor-image ;;
    'inspect --format {{.Image}} monerod') echo monero-image ;;
    *)
        echo "Unexpected engine call: $*" >&2
        return 1
        ;;
    esac
}
compose_up_checked() {
    printf '%s\n' "$*" >>calls
    if [ "$*" = '-d --no-deps --force-recreate dashboard' ]; then
        [ "$CASE" != recreate-failure ] || return 1
        [ "$CASE" != stale-after-recreate ] || return 0
        cp declared running
    fi
}
probe() (
    CASE=$1
    mkdir -p "$T/$CASE/data" "$T/$CASE/images"
    cd "$T/$CASE"
    export PITHEAD_IMAGES_DIR="$PWD/images" PITHEAD_LOAD_HEARTBEAT_SECS=30
    export PITHEAD_KEEP_RUNNING='' PITHEAD_HOLD_CHAIN=0
    printf 'old-image\n' >images/dashboard.tar
    sha256sum images/dashboard.tar | cut -d' ' -f1 >data/.loaded-dashboard.tar.sha
    printf 'old-image\n' >running
    printf 'candidate-image\n' >images/dashboard.tar
    : >calls
    load_baked_images
    [ "$(cat declared)" = candidate-image ] || fail 'candidate archive was not loaded'
    case "$CASE" in
    matching) cp declared running ;;
    hold) PITHEAD_HOLD_CHAIN=1 ;;
    keep) PITHEAD_KEEP_RUNNING=dashboard ;;
    esac
    stack_up
    [ "${NEGATIVE:-0}" != 1 ] || exit 0
    case "$CASE" in
    keep | diy)
        [ "$(cat running)" = old-image ] || fail 'excluded container was recreated'
        ;;
    *) [ "$(cat running)" = candidate-image ] || fail 'same-tag container stayed stale' ;;
    esac
    if [ "$CASE" = matching ] || [ "$CASE" = keep ] || [ "$CASE" = diy ]; then
        if grep -q -- --force-recreate calls; then fail 'matching or excluded image recreated'; fi
    else
        grep -qx -- '-d --no-deps --force-recreate dashboard' calls || fail 'missing scoped recreation'
    fi
    if [ "$CASE" = hold ]; then
        grep -qx rearm calls || fail 'migration latch was not rearmed'
        grep -qx -- '-d dashboard tor' calls || fail 'migration hold started a chain'
    fi
)
if [ "${1:-}" = --negative ]; then
    NEGATIVE=1 probe "$2"
    exit
fi
for scenario in changed matching hold keep diy; do
    probe "$scenario" >"$T/$scenario.log" 2>&1 || {
        cat "$T/$scenario.log"
        fail "$scenario"
    }
done
for scenario in recreate-failure stale-after-recreate config-failure missing-container inspect-failure empty-declared empty-running; do
    if bash "$0" --negative "$scenario" >"$T/$scenario.log" 2>&1; then fail "$scenario was accepted"; fi
done
echo 'selftest-image-convergence: PASS'
