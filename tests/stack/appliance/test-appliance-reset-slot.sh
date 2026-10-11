# shellcheck shell=bash
: "${STACK_SUITE:?source via tests/stack/run.sh}"
echo "== config-reset preserves only the same previously committed slot =="
RS="$SANDBOX/reset-slot"
mkdir -p "$RS/bin"
cp "$STACK" "$RS/pithead"
printf '%040d\n' 1 >"$RS/BUILD_COMMIT"
printf 'rauc.slot=B\n' >"$RS/cmdline"
cat >"$RS/bin/grub-editenv" <<'STUB'
#!/bin/bash
[ "${GRUB_FAIL:-0}" = 0 ] || exit 1
cat "$RS/state"
STUB
cat >"$RS/bin/rauc" <<'STUB'
#!/bin/bash
[ "$*" = 'status mark-good' ] || exit 2
[ "${RAUC_FAIL:-0}" = 0 ] || exit 1
printf 'B_OK=1\nB_TRY=0\nA_OK=1\nA_TRY=0\n' >"$RS/state"
echo committed >>"$RS/calls"
STUB
cat >"$RS/bin/engine" <<'STUB'
#!/bin/bash
[ "$*" = "inspect --format {{.State.Running}} pithead-wizard" ] || exit 2
printf '%s\n' "${WIZARD_RUNNING:-true}"
STUB
cat >"$RS/bin/systemctl" <<'STUB'
#!/bin/bash
[ "${GATE_PASSED:-1}" = 1 ] || { printf 'ActiveState=activating\nSubState=start\n'; exit 0; }
printf 'ActiveState=active\nSubState=exited\nResult=success\nExecMainStatus=0\nConditionResult=yes\n'
STUB
printf '#!/bin/bash\nexit 0\n' >"$RS/bin/docker"
cp "$RS/bin/docker" "$RS/bin/sudo"
chmod +x "$RS/bin/"*
export RS PITHEAD_APPLIANCE=1 PITHEAD_CMDLINE="$RS/cmdline" PITHEAD_BUILD_COMMIT_FILE="$RS/BUILD_COMMIT" PITHEAD_GRUBENV="$RS/grubenv"
rs_call() { PATH="$RS/bin:$PATH" run_sourced "$RS" "$@"; }
rs_seed() {
    printf 'B_OK=1\nB_TRY=0\nA_OK=1\nA_TRY=0\n' >"$RS/state"
    rm -f "$RS/.config-reset-good-slot" "$RS/calls"
}
rs_seed
printf '{}\n' >"$RS/config.json"
out=$(cd "$RS" && PATH="$RS/bin:$PATH" PITHEAD_REBOOT_CMD=true ./pithead config-reset -y 2>&1)
assert_rc "real config-reset records a committed slot before reboot" "$?" 0
assert_eq "record binds the booted slot and exact image source" "$(cat "$RS/.config-reset-good-slot" 2>/dev/null)" "B|$(cat "$RS/BUILD_COMMIT")"
assert_eq "reset record is owner-only" "$(stat -c %a "$RS/.config-reset-good-slot" 2>/dev/null)" 600
printf 'B_OK=1\nB_TRY=1\nA_OK=1\nA_TRY=0\n' >"$RS/state"
rs_call reset_slot_restore_good engine >/dev/null
assert_rc "clean firstboot restores the previously good slot" "$?" 0
assert_contains "RAUC cleared the consumed boot attempt" "$(cat "$RS/state")" B_TRY=0
assert_eq "successful restoration consumes the reset record" "$([ -e "$RS/.config-reset-good-slot" ] && echo present || echo absent)" absent
rs_call reset_slot_restore_good engine >/dev/null
assert_eq "ordinary firstboot cannot commit without a reset record" "$(wc -l <"$RS/calls" | tr -d ' ')" 1
for rs_case in pending bad gate; do
    rs_seed
    case "$rs_case" in pending) printf 'B_OK=1\nB_TRY=1\n' >"$RS/state" ;; bad) printf 'B_OK=0\nB_TRY=0\n' >"$RS/state" ;; esac
    if [ "$rs_case" = gate ]; then
        GATE_PASSED=0 rs_call reset_slot_record_good >/dev/null
    else
        rs_call reset_slot_record_good >/dev/null
    fi
    assert_eq "$rs_case slot cannot acquire reset authority" "$([ -e "$RS/.config-reset-good-slot" ] && echo present || echo absent)" absent
done
for rs_case in slot source stopped revoked rauc; do
    rs_seed
    rs_call reset_slot_record_good >/dev/null
    case "$rs_case" in
    slot) printf 'rauc.slot=A\n' >"$RS/cmdline" ;;
    source) printf '%040d\n' 2 >"$RS/BUILD_COMMIT" ;;
    revoked) printf 'B_OK=0\nB_TRY=1\n' >"$RS/state" ;;
    esac
    case "$rs_case" in
    stopped) WIZARD_RUNNING=false rs_call reset_slot_restore_good engine >/dev/null 2>&1 ;;
    rauc) RAUC_FAIL=1 rs_call reset_slot_restore_good engine >/dev/null 2>&1 ;;
    *) rs_call reset_slot_restore_good engine >/dev/null 2>&1 ;;
    esac
    assert_eq "$rs_case cannot commit the slot" "$([ -e "$RS/calls" ] && echo committed || echo untouched)" untouched
    case "$rs_case" in
    slot | source) assert_eq "$rs_case mismatch consumes stale authority" "$([ -e "$RS/.config-reset-good-slot" ] && echo present || echo absent)" absent ;;
    stopped | rauc) assert_eq "$rs_case failure retains record for a retry" "$([ -e "$RS/.config-reset-good-slot" ] && echo present || echo absent)" present ;;
    esac
    printf 'rauc.slot=B\n' >"$RS/cmdline"
    printf '%040d\n' 1 >"$RS/BUILD_COMMIT"
done
rs_seed
printf 'unknown\n' >"$RS/BUILD_COMMIT"
rs_call reset_slot_record_good >/dev/null 2>&1
assert_eq "invalid image source cannot acquire reset authority" "$([ -e "$RS/.config-reset-good-slot" ] && echo present || echo absent)" absent
printf '%040d\n' 1 >"$RS/BUILD_COMMIT"
PITHEAD_APPLIANCE=0 rs_call reset_slot_record_good >/dev/null
assert_eq "DIY reset cannot acquire appliance slot authority" "$([ -e "$RS/.config-reset-good-slot" ] && echo present || echo absent)" absent
rs_seed
printf '{}\n' >"$RS/config.json"
out=$(cd "$RS" && PATH="$RS/bin:$PATH" GRUB_FAIL=1 PITHEAD_REBOOT_CMD=true ./pithead config-reset -y 2>&1)
assert_rc "unreadable boot state refuses reset" "$?" 1
assert_contains "boot-state refusal explains that reset did not clear configuration" "$out" "configuration was not cleared"
assert_eq "boot-state refusal leaves config intact" "$([ -f "$RS/config.json" ] && echo kept)" kept
unset RS PITHEAD_APPLIANCE PITHEAD_CMDLINE PITHEAD_BUILD_COMMIT_FILE PITHEAD_GRUBENV rs_case
unset -f rs_call rs_seed
