#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/lib/pithead/01-lifecycle.sh"
source "$ROOT/lib/pithead/14-local-miner.sh"
td=$(mktemp -d)
trap 'rm -rf "$td"' EXIT

probe() (
    local appliance=$1 enabled=$2 hold=$3 compose_rc=$4 miner_rc=$5
    local locked=0 started=0
    export PITHEAD_HOLD_CHAIN=$hold
    export PITHEAD_DEFER_LOCAL_MINER=${6:-${PITHEAD_DEFER_LOCAL_MINER:-0}}
    export REVENUE_CHAIN_CONTAINERS="monerod tari wallet-rpc tari-wallet"
    mutation_lock_acquire() { locked=1; }
    mutation_lock_release() {
        locked=0
        printf 'released\n'
    }
    validate_config_document() { :; }
    log() { :; }
    warn() { :; }
    error() { exit 1; }
    warn_missing_data_dirs() { :; }
    migrate_compose_project() { :; }
    apply_tor_egress_firewall() { :; }
    provision_egress_check_units() { :; }
    provision_lan_guard_check_units() { :; }
    verify_release_images() { :; }
    reconcile_compose_images() { :; }
    print_clearnet_banner() { :; }
    announce_dashboard_url() { :; }
    print_first_run_epilogue() { :; }
    env_get() { printf '%s' "$td"; }
    rearm_sync_gate_marker() { :; }
    docker() { printf 'tor\nmonerod\np2pool\n'; }
    compose_up_checked() {
        [ "$locked" = 1 ] || exit 10
        started=1
        printf 'compose\n'
        return "$compose_rc"
    }
    is_appliance() { [ "$appliance" = 1 ]; }
    machine_role() { printf both; }
    rigforge_dir() { printf '%s' "$td"; }
    config_bool() { printf '%s' "$enabled"; }
    local_miner_hugepages_blocked() { [ "${blocked:-0}" = 1 ]; }
    render_local_miner_config() {
        printf 'render\n'
        printf '{}' >"$td/config.json"
    }
    rigforge_setup_run() {
        [ "$locked:$started" = 1:1 ] || exit 11
        printf 'miner\n'
        return "$miner_rc"
    }
    systemctl() { printf 'systemctl %s\n' "$*" >>"$td/stops"; }
    rm -f "$td/config.json" "$td/stops"
    stack_up
)

check() {
    local expected=$1 actual
    shift
    actual=$(probe "$@")
    [ "$actual" = "$expected" ] || {
        printf 'FAIL: up contract (%s), got %s\n' "$*" "$actual" >&2
        exit 1
    }
}
check $'compose\nrender\nminer\nreleased' 1 true 0 0 0
check $'compose\nreleased' 1 false 0 0 0
grep -qx 'systemctl stop xmrig.service' "$td/stops"
check $'compose\nreleased' 0 true 0 0 0
[ ! -e "$td/stops" ]
check $'compose\nreleased' 1 true 1 0 0
[ ! -e "$td/stops" ]
blocked=1 check $'compose\nreleased' 1 true 0 0 0
grep -qx 'systemctl stop xmrig.service' "$td/stops"
check $'compose\nrender\nminer\nreleased' 1 true 0 0 1
if output=$(probe 1 true 0 1 0); then
    printf 'FAIL: compose failure succeeded\n' >&2
    exit 1
fi
[ "$output" = compose ]

export ROOT td
export -f probe stack_up provision_local_miner
mkdir -p "$td/boot/bin"
cp "$ROOT/os/overlay/pithead-boot-stack-health" "$td/boot/"
python3 - "$ROOT/os/overlay/pithead-boot" "$td/boot/pithead-boot" <<'PY'
import pathlib
import sys

script = pathlib.Path(sys.argv[1]).read_text()
script = script.replace('cd /data/pithead || exit 1', '''cd "$BOOT_TEST_ROOT" || exit 1
gate_url() { printf 'http|fixture|80'; }
gate_target_url() { printf 'http://fixture/'; }
gate_resolve_spec() { :; }
gate_probe_header() { :; }
gate_ready() { return 0; }''')
script = script.replace('/usr/local/sbin/pithead-media-config', ':')
pathlib.Path(sys.argv[2]).write_text(script)
PY
cat >"$td/boot/pithead" <<'EOF'
#!/usr/bin/env bash
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    os_prepare_migration_hold() { return "$BOOT_TEST_MIGRATION_RC"; }
    return 0
fi
case "$1" in
up) probe 1 true "${PITHEAD_HOLD_CHAIN:-0}" 0 0 >>"$BOOT_TEST_TRACE" ;;
local-miner)
    [ -f "$BOOT_TEST_ROOT/committed" ] || exit 91
    printf 'miner-after-commit\n' >>"$BOOT_TEST_TRACE"
    exit 124
    ;;
load-images | render) : ;;
*) exit 92 ;;
esac
EOF
cat >"$td/boot/bin/rauc" <<'EOF'
#!/usr/bin/env bash
[ "$*" = 'status mark-good' ] || exit 93
touch "$BOOT_TEST_ROOT/committed"
printf 'commit\n' >>"$BOOT_TEST_TRACE"
EOF
cat >"$td/boot/bin/timeout" <<'EOF'
#!/usr/bin/env bash
[ "$1" = 1800 ] || exit 94
printf 'timeout 1800\n' >>"$BOOT_TEST_TRACE"
shift
"$@"
EOF
printf '#!/usr/bin/env bash\nprintf "200 100\\n"\n' >"$td/boot/bin/curl"
chmod +x "$td/boot/pithead" "$td/boot/bin/"*
for migration in 0 1; do
    rm -f "$td/boot/committed" "$td/boot/trace"
    BOOT_TEST_ROOT="$td/boot" BOOT_TEST_TRACE="$td/boot/trace" \
        BOOT_TEST_MIGRATION_RC=$((1 - migration)) PATH="$td/boot/bin:$PATH" \
        bash "$td/boot/pithead-boot" >"$td/boot/output" 2>&1
    expected=$'compose\nreleased\ncommit\n'
    [ "$migration" = 0 ] || expected+=$'compose\nreleased\n'
    expected+=$'timeout 1800\nminer-after-commit'
    [ "$(cat "$td/boot/trace")" = "$expected" ] || {
        printf 'FAIL: boot miner order (migration=%s)\n' "$migration" >&2
        cat "$td/boot/trace" >&2
        exit 1
    }
done
check $'compose\nreleased' 1 true 0 0 0 1
[ ! -e "$td/stops" ]
printf 'local miner up selftest: PASS (8 lifecycle cases, normal and migration boot ordering)\n'
