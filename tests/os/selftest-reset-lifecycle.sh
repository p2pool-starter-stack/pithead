#!/usr/bin/env bash
# shellcheck disable=SC2031,SC2034,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
OS_RUN_SUITE=1
# shellcheck source=tests/os/phases/reset.sh
source "$SCRIPT_DIR/phases/reset.sh"

run_case() (
    scenario="$1"
    case_dir="$work/$scenario"
    mkdir -p "$case_dir"
    SERIAL="$case_dir/serial" DISK="$case_dir/disk" VM=fixture-vm
    HARNESS_WALLET=fixture-wallet HARNESS_TARI=fixture-tari
    ip=fixture
    printf 'pit-ABC123\n' >"$SERIAL"
    : >"$case_dir/events"
    : >"$case_dir/results"
    reset_boot=0 restarted=0 sleeps=0 ssh_waits=0

    event() { printf '%s\n' "$*" >>"$case_dir/events"; }
    info() { event "info:$*"; }
    ok() { event "ok:$*"; }
    bad() { event "bad:$*"; }
    sleep() { sleeps=$((sleeps + 1)); }
    _build_image() {
        event build-image
        printf fixture-image
    }
    _vm_boot_disk() { event "boot-disk:$1"; }
    _wait_ssh() {
        ssh_waits=$((ssh_waits + 1))
        event "wait-ssh:$1"
    }
    _wait_setup_page() { event "wait-setup:$1"; }
    provisioning_settled() { event "provisioning-settled:$1"; }
    provisioning_setup_failed() { return 1; }
    provisioning_state() { printf settled; }
    stack_never_up_evidence() { return 1; }
    phase_coordinator_setup_again() { event "setup-again:$1:$2"; }
    _phase_reset_config() { event reset-config; }
    _phase_reset_slot() { event reset-slot; }
    it_skip_leg() { event "skip:$*"; }
    _reboot_wait() {
        event "reboot:$1:$2"
        case "$1" in *factory-reset*) reset_boot=1 ;; esac
    }
    have() { return 1; }
    losetup() {
        case "$*" in
        -f) printf '%s\n' "$case_dir/loop" ;;
        -P*) event "attach:$*" ;;
        -d*) event "detach:$*" ;;
        *) return 1 ;;
        esac
    }
    dd() { event "corrupt:$*"; }
    function [ {
        if builtin [ "$#" -eq 3 ] && builtin [ "$1" = -b ] && builtin [ "$2" = "$case_dir/loopp4" ]; then
            return 0
        fi
        builtin [ "$@"
    }
    virsh() {
        event "direct-virsh:$*"
        return 97
    }
    vm_state() {
        state_call=$(($(grep -c '^vm-state:' "$case_dir/events" || true) + 1))
        event "vm-state:$state_call"
        case "$scenario" in
        state-failed) return 2 ;;
        state-unknown) printf 'unknown\n' ;;
        state-running) printf 'running\n' ;;
        state-delayed) if [ "$state_call" -lt 4 ]; then printf 'running\n'; else printf 'shut off\n'; fi ;;
        final-running) if [ "$state_call" -eq 1 ]; then printf 'shut off\n'; else printf 'running\n'; fi ;;
        *) printf 'shut off\n' ;;
        esac
    }
    vm_start() {
        event vm-start
        printf 'start diagnostic\n'
        [ "$scenario" != start-failed ] || return 8
        restarted=1
    }
    curl() {
        case "$*" in
        *'/auth'*)
            while [ "$#" -gt 0 ]; do
                if [ "$1" = -c ]; then
                    printf 'wizard_session\n' >"$2"
                    return
                fi
                shift
            done
            return 1
            ;;
        *'/api/handoff'*) printf '{"username":"fixture-user","password":"fixture-pass"}' ;;
        *'/submit'* | *'/handoff-ack'*) printf 200 ;;
        *) return 1 ;;
        esac
    }
    _ssh() {
        event "ssh:$*"
        case "$*" in
        *'podman ps --format'*) printf 'dashboard\ncaddy\n' ;;
        'cat /etc/machine-id')
            if [ "$reset_boot" -eq 0 ]; then printf machine-before; else printf machine-after; fi
            ;;
        *'ssh-keygen -lf'*)
            if [ "$reset_boot" -eq 0 ]; then printf '256 fingerprint-before fixture'; else printf '256 fingerprint-after fixture'; fi
            ;;
        *'podman images --format'*)
            if [ "$reset_boot" -eq 0 ]; then printf 'dashboard\nmonero\n'; else printf 'dashboard\n'; fi
            ;;
        'test -f /data/pithead/config.json') return 1 ;;
        *'/sys/class/dmi/id/product_uuid'*) printf dmi-fixture ;;
        *'data-wiped.json'*) printf '{"reason":"factory-reset requested","recovery":false}' ;;
        *'pithead-data-wiped.pending'*) return 1 ;;
        *'PITHEAD_ENGINE=podman ./pithead doctor'*)
            [ "$restarted" -eq 0 ] && printf 'Data reset: fixture\n'
            ;;
        *'.battery-sentinel'*)
            case "$*" in
            mkdir*) event plant-sentinel ;;
            cat*) [ "$scenario" != sentinel-lost ] && printf 'IRREPLACEABLE-KEY-MATERIAL\n' ;;
            esac
            ;;
        *'wc -l < /boot/efi/pithead-data-wiped'*)
            if [ "$scenario" = extra-wipe ] && [ "$restarted" -eq 1 ]; then printf 2; else printf 1; fi
            ;;
        'systemctl poweroff') event poweroff ;;
        esac
        return 0
    }

    phase_reset
    state_calls=$(grep -c '^vm-state:' "$case_dir/events" || true)
    printf 'state_calls=%s\nsleeps=%s\nssh_waits=%s\n' "$state_calls" "$sleeps" "$ssh_waits" >"$case_dir/results"
)

run_case success
success="$work/success/events"
grep -Fxq reset-config "$success"
grep -Fxq reset-slot "$success"
grep -Fxq 'setup-again:fixture-user:fixture-pass' "$success"
grep -Fxq poweroff "$success"
grep -Fxq vm-start "$success"
grep -Fq 'attach:-P ' "$success"
grep -Fq 'corrupt:if=/dev/zero ' "$success"
grep -Fq 'detach:-d ' "$success"
grep -Fq 'ok:/data SURVIVED the corrupt superblock' "$success"
grep -Fq 'ok:the ESP wipe log did not grow (1 line(s)' "$success"
grep -Fq 'ok:a genuinely new boot is silent' "$success"
if grep -q '^direct-virsh:\|^bad:' "$success"; then exit 1; fi
grep -E '^(reset-config$|reset-slot$|poweroff$|vm-state:1$|attach:|corrupt:|detach:|vm-start$|wait-ssh:300$|ok:/data SURVIVED|ok:the ESP wipe log did not grow|ok:a genuinely new boot is silent)' "$success" >"$work/success-order"
printf '%s\n' reset-config reset-slot poweroff vm-state:1 \
    "attach:-P $work/success/loop $work/success/disk" \
    'corrupt:if=/dev/zero of='"$work/success/loop"'p4 bs=1 seek=1080 count=2 conv=notrunc' \
    "detach:-d $work/success/loop" vm-start wait-ssh:300 \
    'ok:/data SURVIVED the corrupt superblock — it was repaired, not erased (#1062)' \
    "ok:the ESP wipe log did not grow (1 line(s), from leg 1's real factory reset) — a repair is not recorded as a wipe" \
    'ok:a genuinely new boot is silent — the historic wipe surfaced once and stays surfaced only within its own boot' >"$work/expected-order"
cmp "$work/expected-order" "$work/success-order"
[ "$(grep -c '^wait-setup:120$' "$success")" -eq 3 ]

for scenario in state-failed state-unknown state-running; do
    run_case "$scenario"
    events="$work/$scenario/events"
    grep -Fxq 'bad:guest never powered off cleanly before corrupting the data partition' "$events"
    if grep -q '^attach:\|^corrupt:\|^vm-start$' "$events"; then exit 1; fi
    grep -Fxq state_calls=61 "$work/$scenario/results"
    grep -Fxq sleeps=60 "$work/$scenario/results"
done

run_case state-delayed
grep -Fxq state_calls=5 "$work/state-delayed/results"
grep -Fxq sleeps=4 "$work/state-delayed/results"
grep -Fxq vm-start "$work/state-delayed/events"

run_case final-running
grep -Fxq state_calls=2 "$work/final-running/results"
grep -Fxq 'bad:guest never powered off cleanly before corrupting the data partition' "$work/final-running/events"
if grep -q '^attach:\|^corrupt:\|^vm-start$' "$work/final-running/events"; then exit 1; fi

run_case start-failed
grep -Fxq vm-start "$work/start-failed/events"
grep -Fxq 'bad:guest would not start after the corruption' "$work/start-failed/events"
grep -Fxq ssh_waits=1 "$work/start-failed/results"

run_case sentinel-lost
grep -Fq 'bad:DATA LOSS' "$work/sentinel-lost/events"
run_case extra-wipe
grep -Fq 'bad:a repaired /data recorded a wipe on the ESP (1 -> 2)' "$work/extra-wipe/events"

(
    OS_RUN_SUITE=1 VM=fixture-vm
    # shellcheck source=tests/os/kvm-preflight.sh
    source "$SCRIPT_DIR/kvm-preflight.sh"
    virsh() {
        printf '%s\n' "$*" >"$work/wrapper-args"
        printf 'wrapper output\n'
        return "$wrapper_rc"
    }
    wrapper_rc=0
    [ "$(vm_start)" = 'wrapper output' ]
    [ "$(cat "$work/wrapper-args")" = 'start fixture-vm' ]
    wrapper_rc=23
    rc=0
    output=$(vm_start) || rc=$?
    [ "$rc" -eq 23 ]
    [ "$output" = 'wrapper output' ]
    [ "$(cat "$work/wrapper-args")" = 'start fixture-vm' ]
)

printf 'selftest-reset-lifecycle: PASS\n'
