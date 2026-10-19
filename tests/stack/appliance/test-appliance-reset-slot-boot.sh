# shellcheck shell=bash
: "${STACK_SUITE:?source via tests/stack/run.sh}"
echo "== reset recovery routes replay the shipped GRUB selection and unit conditions =="
RB="$SANDBOX/reset-slot-boot"
mkdir -p "$RB/bin" "$RB/data/pithead"
cp "$STACK" "$RB/data/pithead/pithead"
# GRUB's selection statements are shell-compatible after removing its `set` keyword.
# Execute the shipped block, rather than copying its algorithm into a test double.
sed -n '/^set SELECTED=0/,/^save_env A_TRY A_OK B_TRY B_OK ORDER/p' "$ROOT/os/rauc/grub.cfg" |
    sed -e 's/^set //' -e '/^save_env /d' >"$RB/select.sh"
cat >"$RB/bin/grub-editenv" <<'STUB'
#!/bin/bash
cat "$RB/state"
STUB
cat >"$RB/bin/systemctl" <<'STUB'
#!/bin/bash
if [ "${RB_GATE:-passed}" = failed ]; then
    printf 'ActiveState=failed\nResult=exit-code\n'
else
    printf 'ActiveState=active\nSubState=exited\nResult=success\nExecMainStatus=0\nConditionResult=yes\n'
fi
STUB
cat >"$RB/bin/engine" <<'STUB'
#!/bin/bash
printf 'true\n'
STUB
cat >"$RB/bin/rauc" <<'STUB'
#!/bin/bash
slot=$(sed -n 's/rauc.slot=//p' "$RB/cmdline")
sed -i "s/^${slot}_TRY=.*/${slot}_TRY=0/" "$RB/state"
STUB
chmod +x "$RB/bin/"*
export RB PITHEAD_APPLIANCE=1 PITHEAD_CMDLINE="$RB/cmdline" PITHEAD_BUILD_COMMIT_FILE="$RB/source" PITHEAD_GRUBENV="$RB/grubenv"
rb_call() { PATH="$RB/bin:$PATH" run_sourced "$RB/data/pithead" "$@"; }
rb_seed() {
    printf 'ORDER="B A"\nA_OK=1\nA_TRY=0\nB_OK=1\nB_TRY=0\n' >"$RB/state"
    printf 'rauc.slot=B\n' >"$RB/cmdline"
    printf '%040d\n' 1 >"$RB/source"
    rm -f "$RB/data/pithead/config.json" "$RB/data/pithead/.config-reset-good-slot"
}
rb_unit_runs() { # Read triggering OR and ordinary AND conditions from the shipped unit.
    local path trigger=no trigger_ok=no
    while IFS= read -r path; do
        case "$path" in
        \|*)
            trigger=yes
            [ ! -e "$RB${path#|}" ] || trigger_ok=yes
            ;;
        !*) [ ! -e "$RB${path#!}" ] || return 1 ;;
        *) [ -e "$RB$path" ] || return 1 ;;
        esac
    done < <(sed -n 's/^ConditionPathExists=//p' "$ROOT/os/overlay/$1.service")
    [ "$trigger" = no ] || [ "$trigger_ok" = yes ]
}
rb_boot() {
    (
        # shellcheck disable=SC1091 # generated from the real grub.cfg above
        source "$RB/state"
        # shellcheck disable=SC1091
        source "$RB/select.sh"
        printf 'ORDER="%s"\nA_OK=%s\nA_TRY=%s\nB_OK=%s\nB_TRY=%s\n' "$ORDER" "$A_OK" "$A_TRY" "$B_OK" "$B_TRY" >"$RB/state"
        printf 'rauc.slot=%s\n' "$CURRENT_SLOT" >"$RB/cmdline"
    )
    if rb_unit_runs pithead-firstboot; then
        rb_call reset_slot_restore_good engine >/dev/null
    elif rb_unit_runs pithead-boot; then
        # Successful provisioned health gate: the real cleanup helper and RAUC adapter.
        PATH="$RB/bin:$PATH" rauc status mark-good
        (
            cd "$RB/data/pithead" || exit 1
            # shellcheck disable=SC1091 # ROOT is the suite's real tree
            source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
            boot_gate_passed
        )
    fi
}
rb_seed
rb_call reset_slot_record_good
rb_boot
printf '{}\n' >"$RB/data/pithead/config.json"
rb_boot
assert_eq "wizard setup route reboots to B" "$(cat "$RB/cmdline")" rauc.slot=B
assert_eq "successful provisioned gate consumes reset authority" "$([ -f "$RB/data/pithead/.config-reset-good-slot" ] && echo present || echo absent)" absent

rb_seed
rb_call reset_slot_record_good
rb_boot
# CLI restore recreates the file that switches the shipped unit conditions to pithead-boot.
printf '{}\n' >"$RB/data/pithead/config.json"
rb_boot
assert_eq "CLI restore route reboots to B" "$(cat "$RB/cmdline")" rauc.slot=B

rb_seed
rb_call reset_slot_record_good
rb_boot
rb_boot
assert_eq "reboot with setup still open stays on B" "$(cat "$RB/cmdline")" rauc.slot=B
printf '{}\n' >"$RB/data/pithead/config.json"
rb_boot
assert_eq "setup after its open-page reboot still reboots to B" "$(cat "$RB/cmdline")" rauc.slot=B

rb_seed
rb_boot
rb_boot
assert_eq "unverified spare update with an open wizard falls back to A" "$(cat "$RB/cmdline")" rauc.slot=A
rb_seed
RB_GATE=failed rb_call reset_slot_record_good
rb_boot
rb_boot
assert_eq "failed provisioned gate never grants reset authority and falls back to A" "$(cat "$RB/cmdline")" rauc.slot=A
rb_seed
rb_call reset_slot_record_good
printf '%040d\n' 2 >"$RB/source"
rb_boot
rb_boot
assert_eq "different immutable source cannot reuse reset authority and falls back to A" "$(cat "$RB/cmdline")" rauc.slot=A
rb_seed
rb_call reset_slot_record_good
printf 'B_TRY=1\n' >>"$RB/state"
printf '{}\n' >"$RB/data/pithead/config.json"
rb_call reset_slot_restore_good engine
assert_contains "retained authority cannot commit a provisioned setup-again coordinator" "$(cat "$RB/state")" B_TRY=1
rm -f "$RB/data/pithead/config.json"
printf 'rig\n' >"$RB/data/pithead/machine-role"
rb_call reset_slot_restore_good engine
assert_contains "retained authority cannot commit a provisioned setup-again rig" "$(cat "$RB/state")" B_TRY=1
unset RB PITHEAD_APPLIANCE PITHEAD_CMDLINE PITHEAD_BUILD_COMMIT_FILE PITHEAD_GRUBENV
unset -f rb_call rb_seed rb_unit_runs rb_boot
