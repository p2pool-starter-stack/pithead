#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OS_RUN_SUITE=1
# shellcheck source=tests/os/phases/install-rig.sh
source "$HERE/phases/install-rig.sh"
TASK_DIR=$(mktemp -d)
trap 'rm -rf "$TASK_DIR"' EXIT
fixture_token=0123456789abcdef0123456789abcdef
snapshot=$(jq -nc --arg t "$fixture_token" '{rig:{access_token:$t,worker:"kvm-installed-rig",pool:"127.0.0.1:22"},
    miner:{ACCESS_TOKEN:$t,pools:[{user:"kvm-installed-rig",url:"127.0.0.1:22"}]},
    role:"rig",root:"vda",esp_root:"vda",esp_type:"vfat",active:"active",pid:"42",containers:"",coordinator:"absent",seed:"absent"}')
printf '%s' "$snapshot" | _phase_install_rig_verdict "$fixture_token"
for change in \
    '.rig.access_token = "ffffffffffffffffffffffffffffffff"' \
    '.miner.ACCESS_TOKEN = "ffffffffffffffffffffffffffffffff"' \
    '.rig.worker = "other"' '.rig.pool = "other:3333"' \
    '.miner.pools[0].user = "other"' '.miner.pools[0].url = "other:3333"' \
    '.role = "coordinator"' '.root = "sda"' '.esp_root = "sda"' '.esp_type = "ext4"' 'del(.esp_root)' 'del(.esp_type)' '.active = "inactive"' \
    '.pid = "0"' '.pid = ""' '.pid = "unreadable"' \
    '.containers = "stopped-container"' '.coordinator = "present"' '.seed = "present"' \
    'del(.rig)' 'del(.miner)' 'del(.root)' 'del(.containers)' 'del(.seed)' 'del(.coordinator)'; do
    if printf '%s' "$snapshot" | jq "$change" | _phase_install_rig_verdict "$fixture_token"; then
        echo "accepted invalid installed rig: $change" >&2
        exit 1
    fi
done
for invalid in '' null '{}' 'not-json'; do
    if printf '%s' "$invalid" | _phase_install_rig_verdict "$fixture_token"; then
        echo 'accepted missing or malformed guest evidence' >&2
        exit 1
    fi
done
if printf '%s' "$snapshot" | _phase_install_rig_verdict ''; then
    echo 'accepted a missing card token' >&2
    exit 1
fi
if printf '%s' "$snapshot" | _phase_install_rig_verdict 'ffffffffffffffffffffffffffffffff'; then
    echo 'accepted a different card token' >&2
    exit 1
fi
image="$TASK_DIR/image"
touch "$image"
_build_image() { printf '%s' "$image"; }
vm_destroy_or_refuse() { :; }
kvm_preflight() { :; }
_wait_dhcp_ip() {
    [ "$flow_case" != dhcp-failure ] || return 1
    ip=guest.example
}
_wait_ssh() { :; }
_wait_setup_page() { :; }
sleep() { :; }
ok() { printf '%s\n' "$1" >>"$TASK_DIR/passes"; }
bad() { printf '%s\n' "$1" >>"$TASK_DIR/failures"; }
info() { :; }
qemu-img() {
    if [ "$1" = create ]; then
        [ ! -e "$4" ] && touch "$4"
    fi
}
virsh() { printf 'shut off\n'; }
virt-install() {
    printf '%s\n' "$*" >>"$TASK_DIR/boots"
    printf 'pit-ABC123\n' >"$SERIAL"
}
curl() {
    local args="$*" previous="" value
    for value in "$@"; do
        if [ "$previous" = -c ]; then printf 'wizard_session\n' >"$value"; fi
        previous="$value"
    done
    case "$args" in
    */auth*) return 0 ;;
    */submit*)
        case "$args" in
        *'role=rig&rig_pool=127.0.0.1:22&rig_worker=kvm-installed-rig&disk=vda&confirm=vda&wipe=keep'*) printf 200 ;;
        *) printf 400 ;;
        esac
        ;;
    */api/handoff*)
        jq -nc --arg t "$fixture_token" '{role:"rig",worker:"kvm-installed-rig",stratum:"stratum+tcp://127.0.0.1:22",token:$t}'
        ;;
    */handoff-ack*)
        [ "$flow_case" != ack-failure ] || return 1
        touch "$TASK_DIR/acked"
        ;;
    *) return 1 ;;
    esac
}
_ssh() {
    [ "$flow_case" != ssh-failure ] || return 1
    if [ "$flow_case" = token-mismatch ]; then
        printf '%s' "$snapshot" | jq '.rig.access_token = "ffffffffffffffffffffffffffffffff"'
    else
        printf '%s' "$snapshot"
    fi
}
for flow_case in success ack-failure ssh-failure token-mismatch dhcp-failure; do
    rm -f "$TASK_DIR/boots" "$TASK_DIR/passes" "$TASK_DIR/failures" "$TASK_DIR/acked"
    export VM=selftest DISK="$TASK_DIR/stick" SERIAL="$TASK_DIR/serial" target_disk="$TASK_DIR/target"
    export img="" ip=""
    touch "$target_disk"
    result=0
    _phase_install_rig || result=$?
    if [ "$flow_case" = success ]; then
        [ "$result" -eq 0 ] && [ ! -e "$TASK_DIR/failures" ] && [ -e "$TASK_DIR/acked" ]
        [ "$(wc -l <"$TASK_DIR/boots" | tr -d ' ')" = 2 ]
        first_boot=$(head -1 "$TASK_DIR/boots")
        last_boot=$(tail -1 "$TASK_DIR/boots")
        [[ "$first_boot" == *"path=$DISK,format=raw,bus=usb,removable=on"* ]]
        [[ "$first_boot" == *"path=$target_disk,format=raw,bus=virtio"* ]]
        [[ "$last_boot" == *"path=$target_disk,format=raw,bus=virtio"* ]]
        [[ "$last_boot" != *"path=$DISK,"* ]]
    else
        [ "$result" -ne 0 ] && [ -s "$TASK_DIR/failures" ]
        if [ "$flow_case" = ack-failure ]; then
            [ "$(wc -l <"$TASK_DIR/boots" | tr -d ' ')" = 1 ]
        fi
    fi
done
printf 'internal-disk rig self-test: PASS\n'
