#!/usr/bin/env bash
# The KVM boot-probe verdict rejects absent, stale, leaked and miscounted evidence.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HERE/boot-probe-evidence.py" --self-test

# Drive the real reboot gate against a retained RAUC flag and a delayed current journal.
OS_RUN_SUITE=1 source "$HERE/phases/provision-reboot.sh"
_ssh() {
    [ "$1" = "journalctl -b -u pithead-boot.service --no-pager -o cat | grep -Eq '^pithead-boot: stack is serving .* — booted slot committed'" ] || {
        echo "FAIL: commit check did not restrict itself to the current boot" >&2
        exit 1
    }
    journal_reads=$((journal_reads + 1))
    [ "$journal_reads" -ge "$commit_after" ]
}
journal_reads=0 commit_after=3
if _provision_reboot_gate_committed 'A_OK=1 A_TRY=0'; then
    echo 'FAIL: retained RAUC flags accepted before this boot committed' >&2
    exit 1
fi
[ "$journal_reads" = 1 ]
if _provision_reboot_gate_committed 'A_OK=0 A_TRY=1'; then
    echo 'FAIL: uncommitted slot accepted' >&2
    exit 1
fi
[ "$journal_reads" = 1 ]
# Execute the phase's actual polling block, not a copy of its retry logic.
sleep() { [ "$1" = 10 ]; }
_ssh() {
    case "$1" in
    'grub-editenv /boot/efi/grub/grubenv list') printf 'A_OK=1\nA_TRY=0\n' ;;
    "journalctl -b -u pithead-boot.service --no-pager -o cat | grep -Eq '^pithead-boot: stack is serving .* — booted slot committed'")
        journal_reads=$((journal_reads + 1))
        [ "$journal_reads" -ge "$commit_after" ]
        ;;
    *)
        echo 'FAIL: unexpected gate command' >&2
        exit 1
        ;;
    esac
}
ok() { gate_passes=$((gate_passes + 1)); }
bad() {
    echo "FAIL: $*" >&2
    exit 1
}
gate_passes=0
_gate_poll() {
    eval "$(sed -n '/^    local genv tries3=0/,/^    # Read this boot/ { /^    # Read this boot/!p; }' "$HERE/phases/provision-reboot.sh")"
}
_gate_poll
[ "$journal_reads" = 4 ] && [ "$gate_passes" = 1 ]
printf 'boot-probe current-boot gate selftest passed\n'
