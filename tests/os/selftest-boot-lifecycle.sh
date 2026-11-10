#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
OS_RUN_SUITE=1
VM=fixture-vm
IMAGE="$scratch/image"
DISK="$scratch/disk"
SERIAL="$scratch/serial"
SCRIPT_DIR="$HERE"
PASS=0
FAIL=0
export scratch

mkdir "$scratch/bin"
cat >"$scratch/bin/virt-install" <<'STUB'
#!/usr/bin/env bash
printf 'virt-install' >>"$scratch/virt-install.calls"
printf ' <%s>' "$@" >>"$scratch/virt-install.calls"
printf '\n' >>"$scratch/virt-install.calls"
exit "${VIRT_INSTALL_RC:-0}"
STUB
chmod +x "$scratch/bin/virt-install"
PATH="$scratch/bin:$PATH"

# shellcheck source=tests/os/kvm-preflight.sh
source "$HERE/kvm-preflight.sh"

fail() {
    printf 'boot-lifecycle selftest: FAIL: %s\n' "$*" >&2
    exit 1
}

expect_line() {
    local want="$1" file="$2"
    grep -Fxq "$want" "$file" || {
        printf 'missing line: %s\n' "$want" >&2
        sed -n '1,80p' "$file" >&2
        exit 1
    }
}

: >"$DISK"
: >"$SERIAL"
vm_create "$DISK" "$SERIAL" no
vm_create "$DISK" "$SERIAL" yes
expected_plain="virt-install <--name> <$VM> <--memory> <16384> <--vcpus> <4> <--cpu> <host-passthrough> <--osinfo> <debian12> <--boot> <uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no> <--import> <--disk> <path=$DISK,format=raw,bus=virtio> <--network> <network=default,model=virtio> <--graphics> <none> <--serial> <file,path=$SERIAL> <--noautoconsole>"
expected_secure="${expected_plain/firmware.feature0.enabled=no/firmware.feature0.enabled=yes}"
expect_line "$expected_plain" "$scratch/virt-install.calls"
expect_line "$expected_secure" "$scratch/virt-install.calls"
VIRT_INSTALL_RC=23
export VIRT_INSTALL_RC
expect_rc=0
vm_create "$DISK" "$SERIAL" no >/dev/null 2>&1 || expect_rc=$?
unset VIRT_INSTALL_RC
[ "$expect_rc" -eq 23 ] || fail "vm_create hid virt-install exit status $expect_rc"

# shellcheck source=tests/os/phases/boot.sh
source "$HERE/phases/boot.sh"
cd "$scratch"

scenario_reset() {
    : >"$scratch/events"
    printf 'image\n' >"$IMAGE"
    printf 'stale serial\n' >"$SERIAL"
    rm -f "$DISK"
    destroy_rc=0
    preflight_rc=0
    create_rc=0
    serial_rc=1
    dhcp_rc=0
}

event() { printf '%s\n' "$*" >>"$scratch/events"; }
info() { event "info $*"; }
ok() { event "ok $*"; }
bad() { event "bad $*"; }
vm_destroy_or_refuse() {
    event destroy
    return "$destroy_rc"
}
cp() {
    event "copy $1 $2"
    command cp "$@"
}
qemu-img() {
    event "resize $*"
    return 0
}
kvm_preflight() {
    event preflight
    return "$preflight_rc"
}
vm_create() {
    [ ! -s "$2" ] || fail "vm_create saw an untruncated serial log"
    event "create $1 $2 $3"
    return "$create_rc"
}
wait_serial() {
    event "wait-serial $1 $2"
    return "$serial_rc"
}
_wait_dhcp_ip() {
    event "wait-dhcp $1"
    return "$dhcp_rc"
}
secure_boot_boot_verdict() {
    event "secure-verdict $1 $2 $3"
    return 0
}

assert_order() {
    local previous=0 pattern line
    for pattern in "$@"; do
        line=$(grep -nFx "$pattern" "$scratch/events" | head -1 | cut -d: -f1)
        [ -n "$line" ] || fail "missing event '$pattern'"
        [ "$line" -gt "$previous" ] || fail "event out of order: '$pattern'"
        previous=$line
    done
}

scenario_reset
phase_boot
assert_order destroy "copy $IMAGE $DISK" "resize resize $DISK 40G" preflight \
    "create $DISK $SERIAL no" "wait-serial login:|Debian GNU/Linux|Pithead setup wizard 240" \
    "bad no userspace banner on serial within 240s — boot failed; check the serial log"
[ "$(cat "$DISK")" = image ] || fail "phase_boot did not preserve the disk copy"
! grep -Fq 'wait-dhcp' "$scratch/events" || fail "phase_boot continued after its first failed wait"

scenario_reset
create_rc=1
phase_boot
expect_line "bad virt-install failed to define the VM" "$scratch/events"
! grep -Fq 'wait-serial' "$scratch/events" || fail "phase_boot waited after creation failed"

scenario_reset
destroy_rc=1
if phase_boot; then
    fail "phase_boot hid a teardown failure"
fi
[ "$(wc -l <"$scratch/events")" -eq 2 ] || fail "phase_boot continued after teardown failed"
expect_line destroy "$scratch/events"

scenario_reset
if (
    preflight_rc=1
    phase_boot
); then
    fail "phase_boot ignored a failed preflight"
fi
! grep -Fq 'create ' "$scratch/events" || fail "phase_boot created a VM after failed preflight"

printf 'fixture-version\n' >VERSION
scenario_reset
serial_rc=0
_secure_boot_guest_leg
assert_order destroy "copy $IMAGE $DISK" "resize resize $DISK 40G" preflight \
    "create $DISK $SERIAL yes" "wait-serial login:|Debian GNU/Linux|Pithead setup wizard 180" \
    "secure-verdict 1 1 fixture-version"

scenario_reset
create_rc=1
_secure_boot_guest_leg
expect_line "secure-verdict 0 0 fixture-version" "$scratch/events"
! grep -Fq 'wait-serial' "$scratch/events" || fail "secure boot waited after creation failed"

alternate="$scratch/alternate"
printf 'alternate\n' >"$alternate"
scenario_reset
_vm_boot_disk "$alternate"
assert_order destroy "copy $alternate $DISK" "resize resize $DISK 40G" preflight \
    "create $DISK $SERIAL no" "wait-dhcp 120"
[ "$(cat "$DISK")" = alternate ] || fail "_vm_boot_disk did not preserve the disk copy"

scenario_reset
create_rc=1
if _vm_boot_disk "$alternate"; then
    fail "_vm_boot_disk hid a creation failure"
fi
! grep -Fq 'wait-dhcp' "$scratch/events" || fail "_vm_boot_disk polled DHCP after creation failed"

[ "$(wc -l <"$scratch/virt-install.calls")" -eq 3 ] ||
    fail "a boot caller bypassed vm_create"
printf 'boot-lifecycle selftest: PASS\n'
