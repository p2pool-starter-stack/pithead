# shellcheck shell=bash
: "${STACK_SUITE:?source via tests/stack/run.sh}"
echo "== unit: the appliance boot leg tells lock contention from a bad slot (#1342) =="
# pithead-boot's fail_boot reboots on the first failed boot so the bootloader falls back to the
# other A/B slot, and on the second declares that the fault is not the slot. There is no systemd
# ordering between pithead-firstboot and pithead-boot, so `./pithead up` here can collide with the
# wizard's `setup` window — and a collision routed through fail_boot spends the one fallback the
# box has on a slot that is fine, then misdiagnoses itself. Sourcing the boot script defines its
# functions and runs none of it (its BASH_SOURCE guard), so this drives the real routing.
BOOTC="$SANDBOX/bootcontend"
mkdir -p "$BOOTC"
boot_up_probe() { # <exit status from `pithead up`> -> "<counter>|<rebooted?>|<which message>"
    local out verdict=other
    rm -f "$BOOTC/.boot-gate-failures" "$BOOTC/rebooted"
    # Both branches report on STDERR, so the redirect belongs to the subshell and INSIDE the
    # capture: `$(...) 2>&1` sends it to the caller's stderr instead and leaves $out empty.
    out=$( (
        cd "$BOOTC" || exit 9
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot"
        # shellcheck disable=SC2034  # both are read by the sourced boot script, not by this shell
        BOOT_FAIL_COUNT="$BOOTC/.boot-gate-failures"
        # shellcheck disable=SC2034
        PITHEAD_REBOOT_CMD="touch $BOOTC/rebooted"
        boot_up_failed "$1"
    ) 2>&1)
    # Each branch is read on the one sentence ONLY it writes, and the other's absence is asserted
    # by the verdict being a single value: both messages mention the A/B fallback, so keying on
    # that shared phrase would let either branch stand in for the other.
    case "$out" in *"contention, NOT a bad slot"*) verdict=contended ;; esac
    case "$out" in *"slot left uncommitted so"*) verdict="$verdict+slotfailure" ;; esac
    printf '%s|%s|%s' \
        "$(cat "$BOOTC/.boot-gate-failures" 2>/dev/null || echo none)" \
        "$([ -f "$BOOTC/rebooted" ] && echo rebooted || echo no-reboot)" "$verdict"
}
assert_eq "a lock timeout spends no A/B fallback, is not counted, and says it is contention" \
    "$(boot_up_probe 75)" "none|no-reboot|contended"
assert_eq "any other failed up still reads as a bad slot and falls back" \
    "$(boot_up_probe 1)" "1|rebooted|other+slotfailure"
unset -f boot_up_probe

# THE WIZARD'S HALF OF THE SAME ROUTING — the leg #1342 left unrouted, recreating #1059's shape.
#
# The block above proves the BOOT leg tells contention from a bad slot. `setup` runs inside a
# mutating window too and can lose the same race, but every non-zero (setup) was routed as a
# provisioning failure: the operator is told their configuration is wrong and asked to correct it,
# on a first boot where there is no shell to contradict it. Worse, that path calls
# wizard_keep_failed_config, which REMOVES config.json when the machine-role marker never landed —
# and record_machine_role is best-effort (`printf ... || true`).
#
# THE FIXTURE IS CHOSEN TO MAKE THE REMOVAL REACHABLE: config.json present, machine-role ABSENT.
# With the marker present nothing is removed on either branch, both rows would read "kept", and
# this pair could not fail for any change to the routing.
WIZC="$SANDBOX/wizcontend"
wizard_fail_probe() { # <exit status of setup> -> "<config>|<copy>|<verdict>|<rc>"
    local out rc=0 verdict=other
    rm -rf "$WIZC"
    mkdir -p "$WIZC"
    printf '{"monero":{}}\n' >"$WIZC/config.json"
    out=$(run_sourced "$WIZC" wizard_setup_failed "$1" 2>&1) || rc=$?
    # Keyed on a sentence ONLY one branch writes, for the reason the boot probe above gives: both
    # branches mention reopening the setup window, so that shared phrase would let either stand in
    # for the other.
    case "$out" in *"contention, NOT a problem with the configuration"*) verdict=contended ;; esac
    case "$out" in *"so it can be corrected"*) verdict="$verdict+badconfig" ;; esac
    printf '%s|%s|%s|%s' \
        "$([ -f "$WIZC/config.json" ] && echo kept || echo DELETED)" \
        "$([ -f "$WIZC/config.json.failed" ] && echo copied || echo no-copy)" \
        "$verdict" "$rc"
}
# rc is the prefill signal: 0 means a config.json.failed copy was kept and the reopened page fills
# from it, 1 means the live config.json is what the operator gets back.
assert_eq "a lock-timeout setup keeps the operator's configuration and names it as contention" \
    "$(wizard_fail_probe 75)" "kept|no-copy|contended|1"
assert_eq "any other failed setup still copies the config aside and asks for a correction" \
    "$(wizard_fail_probe 1)" "DELETED|copied|other+badconfig|0"
unset -f wizard_fail_probe
