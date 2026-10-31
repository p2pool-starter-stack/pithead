#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2031,SC2329

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# shellcheck disable=SC2034
OS_RUN_SUITE=1 PASS=0 FAIL=0 KEEP=1 VM=pithead-os-test SERIAL="$scratch/serial"
# shellcheck source=tests/os/kvm-preflight.sh
source "$HERE/kvm-preflight.sh"
# shellcheck source=tests/os/lib/core.sh
source "$HERE/lib/core.sh"
trap 'rm -rf "$scratch"' EXIT
SSH_ERR="$scratch/ssh.err"
: >"$SSH_ERR"
fake_state=running state_rc=0 list_rc=0
fake_domains=$'pithead-os-test\nunrelated'
lease=$'vnet0 ignored ipv6 2001:db8::1/64\nvnet0 ignored ipv4 192.0.2.10/24\nvnet1 ignored ipv4 192.0.2.11/24'
export scratch VM fake_state state_rc list_rc fake_domains lease
mkdir "$scratch/bin"
cat >"$scratch/bin/virsh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$scratch/calls"
case "$*" in
"domstate $VM")
    printf '%s\n' "$fake_state"
    exit "$state_rc"
    ;;
"domifaddr $VM") printf '%s\n' "$lease" ;;
'list --name' | 'list --all --name')
    printf '%s\n' "$fake_domains"
    exit "$list_rc"
    ;;
"destroy $VM" | "undefine $VM --nvram") exit 1 ;;
*) exit 99 ;;
esac
STUB
chmod +x "$scratch/bin/virsh"
PATH="$scratch/bin:$PATH"

expect_rc() {
    local expected="$1" got=0
    shift
    "$@" >"$scratch/output" 2>&1 || got=$?
    [ "$got" -eq "$expected" ] || {
        printf 'expected exit %s, got %s: %s\n' "$expected" "$got" "$*" >&2
        cat "$scratch/output" >&2
        exit 1
    }
}
clean_bench() (require_clean_bench)

[ "$(vm_state)" = running ]
[ "$(vm_lease_ip)" = 192.0.2.10 ]
[ "$(vm_list_running)" = "$fake_domains" ]
expect_rc 0 clean_bench
fake_domains=$'pithead-os-test\npithead-stray'
expect_rc 2 clean_bench
grep -Fq 'pithead-stray' "$scratch/output"
list_rc=2
expect_rc 2 vm_list_running
expect_rc 2 clean_bench
grep -Fq 'could not enumerate' "$scratch/output"
list_rc=0

_wait_dhcp_ip 5
[ "$ip" = 192.0.2.10 ]
lease=''
expect_rc 1 _wait_dhcp_ip 1
[ -z "$ip" ]
fake_state='shut off'
out=$(_ssh_unreachable_reason 192.0.2.10)
[[ "$out" == *'not running'* && "$out" == *'shut off'* ]]
fake_state='' state_rc=2
out=$(_ssh_unreachable_reason 192.0.2.10)
[[ "$out" == *'not running'* && "$out" == *unknown* ]]
fake_state=running state_rc=0
lease='vnet0 ignored ipv4 192.0.2.11/24'
out=$(_ssh_unreachable_reason 192.0.2.10)
[[ "$out" == *DIFFERENT* && "$out" == *192.0.2.11* && "$out" == *192.0.2.10* ]]
lease='vnet0 ignored ipv4 192.0.2.10/24'
printf 'Connection refused\n' >"$SSH_ERR"
[[ "$(_ssh_unreachable_reason 192.0.2.10)" == *'refuses port 22'* ]]
printf 'Permission denied\n' >"$SSH_ERR"
[[ "$(_ssh_unreachable_reason 192.0.2.10)" == *'REJECTED our key'* ]]

fake_domains=$VM
expect_rc 1 vm_destroy_or_refuse
fake_domains=''
expect_rc 0 vm_destroy_or_refuse
list_rc=2
expect_rc 1 vm_destroy_or_refuse
printf '%s\n' "destroy $VM" "undefine $VM --nvram" 'list --all --name' >"$scratch/expected"
tail -3 "$scratch/calls" >"$scratch/actual"
cmp "$scratch/expected" "$scratch/actual"

(
    virsh() { return 99; }
    vm_state() { printf 'running\n'; }
    vm_lease_ip() { printf '192.0.2.12\n'; }
    vm_list_running() { printf '%s\n' "$VM"; }
    require_clean_bench
    _wait_dhcp_ip 5
    [ "$ip" = 192.0.2.12 ]
    out=$(_ssh_unreachable_reason 192.0.2.10)
    [[ "$out" == *DIFFERENT* && "$out" == *192.0.2.12* ]]
)
PITHEAD_OS_VM_DESTROY_SELF_TEST=1 bash "$HERE/kvm-preflight.sh"
printf 'vm-lifecycle selftest: PASS\n'
