#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# shellcheck source=tests/os/rig-share-leg.sh
source "${RIG_SHARE_LEG_SOURCE:-$HERE/rig-share-leg.sh}"
RIG_SHARE_WINDOW_SEC=12
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
ok() { printf '%s\n' "$*" >>"$scratch/pass"; }
bad() { printf '%s\n' "$*" >>"$scratch/fail"; }
info() { :; }
date() {
    local tick
    tick=$(cat "$scratch/tick")
    echo "$((tick + 1))" >"$scratch/tick"
    echo "$tick"
}
sleep() { :; }
virsh() {
    printf '%s\n' "$*" >>"$scratch/virsh"
    case "$*" in
    'destroy rig-coord')
        [ "$VM" = rig-coord ] && [ "$ip" = 192.0.2.2 ] || fail "cut targeted the rig"
        [ "$scenario" != destroy-fails ] || return 1
        touch "$scratch/cut"
        ;;
    'start rig-coord') [ "$scenario" != start-fails ] || return 1 ;;
    esac
}
_boot_id() {
    [ "$VM" = rig-coord ] && [ "$ip" = 192.0.2.2 ] || fail "boot read targeted the rig"
    [ "$scenario" != boot-id-missing ] || return 1
    echo old-boot
}
_wait_new_boot() {
    [ "$*" = 'old-boot 300' ] || fail "new-boot gate not used"
    [ "$scenario" != boot-fails ] || return 1
    touch "$scratch/new-boot"
}
curl() {
    local call rig_count own_count
    call=$(cat "$scratch/polls")
    echo "$((call + 1))" >"$scratch/polls"
    if [ ! -f "$scratch/cut" ]; then
        if [ "$scenario" = no-initial-shares ]; then
            echo '{"workers":[]}'
        else
            echo '{"workers":[{"name":"kvm-rig-share","accepted":4},{"name":"builtin","accepted":7}]}'
        fi
        return
    fi
    [ -f "$scratch/new-boot" ] || fail "share polling preceded the new boot"
    printf '%s\n' "$*" >>"$scratch/requests"
    case "$scenario" in
    malformed)
        echo '{broken'
        return
        ;;
    missing-workers)
        echo '{"workers":[]}'
        return
        ;;
    invalid-count)
        echo '{"workers":[{"name":"kvm-rig-share","accepted":"9"},{"name":"builtin","accepted":9}]}'
        return
        ;;
    negative-count)
        echo '{"workers":[{"name":"kvm-rig-share","accepted":-1},{"name":"builtin","accepted":9}]}'
        return
        ;;
    fractional-count)
        echo '{"workers":[{"name":"kvm-rig-share","accepted":1.5},{"name":"builtin","accepted":9}]}'
        return
        ;;
    unavailable) return 22 ;;
    duplicate-worker)
        echo '{"workers":[{"name":"kvm-rig-share","accepted":9},{"name":"builtin","accepted":9},{"name":"unknown","accepted":9}]}'
        return
        ;;
    stale)
        rig_count=4
        own_count=7
        ;;
    rig-only)
        rig_count="$call"
        own_count=7
        ;;
    builtin-only)
        rig_count=4
        own_count="$call"
        ;;
    reset)
        if [ "$call" -eq 1 ]; then
            rig_count=4
            own_count=7
        else
            rig_count=$((call - 2))
            own_count=$((call - 2))
        fi
        ;;
    delayed)
        if [ "$call" -lt 3 ]; then
            echo '{}'
            return
        fi
        rig_count="$call"
        own_count="$call"
        ;;
    *)
        rig_count="$call"
        own_count="$call"
        ;;
    esac
    printf '{"workers":[{"name":"kvm-rig-share","accepted":%s},{"name":"builtin","accepted":%s}]}\n' "$rig_count" "$own_count"
}
kvm_preflight() { return 0; }
_provision_remote_node_coordinator() {
    [ "$VM" = rig-coord ] || fail "wrong coordinator"
    ip=192.0.2.2 dash_user=test dash_pass=fixture
}
_setup_again_boot() { return 0; }
_setup_again_session() {
    jar="$scratch/cookies"
    touch "$jar"
}
_setup_again_rig_submit() { echo 'fixture card'; }
_rig_mining_up() { return 0; }
_ssh() { return 0; }
_rig_share_coord_teardown() { printf '%s\n' "$*" >>"$scratch/teardown"; }
run_case() {
    local scenario="$1" expected="$2" result=0
    local VM=rig DISK="$scratch/rig.img" SERIAL="$scratch/rig.log" ip=192.0.2.1
    for file in pass fail virsh teardown requests; do : >"$scratch/$file"; done
    rm -f "$scratch/cut" "$scratch/new-boot"
    echo 0 >"$scratch/tick"
    echo 0 >"$scratch/polls"
    rig_share_leg image node 18081 18083 '' '' '' '' "$ip" || result=$?
    [ "$result" -eq "$expected" ] || fail "$scenario returned $result, expected $expected"
    [ "$VM" = rig ] && [ "$ip" = 192.0.2.1 ] &&
        [ "$DISK" = "$scratch/rig.img" ] && [ "$SERIAL" = "$scratch/rig.log" ] || fail "$scenario leaked coordinator globals"
    [ "$(wc -l <"$scratch/teardown")" -eq 1 ] || fail "$scenario did not tear down once"
    grep -Fxq "rig-coord $scratch/rig-coord.img $scratch/rig-coord.log" "$scratch/teardown" || fail "$scenario cleaned up the wrong guest"
    if [ "$expected" -eq 0 ]; then
        [ ! -s "$scratch/fail" ] || fail "$scenario reported a failure"
        grep -q "the rig's accepted counter advances after" "$scratch/pass" || fail "$scenario lacks post-cut rig proof"
        grep -q "the built-in miner's accepted counter advances after" "$scratch/pass" || fail "$scenario lacks post-cut builtin proof"
        [ "$(wc -l <"$scratch/virsh")" -eq 2 ] || fail "$scenario did not destroy/start once"
        grep -Fxq 'start rig-coord' "$scratch/virsh" || fail "$scenario did not restore power"
        [ "$(wc -l <"$scratch/requests")" -ge 2 ] || fail "$scenario accepted a single snapshot"
    else
        [ -s "$scratch/fail" ] || fail "$scenario silently failed"
        ! grep -q 'accepted counter advances after' "$scratch/pass" || fail "$scenario claimed post-cut mining"
    fi
    case "$scenario" in
    no-initial-shares | boot-id-missing) [ ! -s "$scratch/virsh" ] || fail "$scenario cut power without a baseline" ;;
    destroy-fails) [ "$(wc -l <"$scratch/virsh")" -eq 1 ] || fail "start followed failed destroy" ;;
    start-fails | boot-fails) [ ! -s "$scratch/requests" ] || fail "$scenario polled before boot proof" ;;
    esac
}
run_case advancing 0
run_case reset 0
run_case delayed 0
for scenario in no-initial-shares boot-id-missing destroy-fails start-fails boot-fails stale rig-only builtin-only malformed missing-workers invalid-count negative-count fractional-count unavailable duplicate-worker; do
    run_case "$scenario" 1
done
printf 'selftest-rig-share-power-cut: 18 cases passed\n'
