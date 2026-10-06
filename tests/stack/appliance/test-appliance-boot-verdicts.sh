# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Two more boot verdicts split out of test-appliance-identity-boot.sh (#2055) rather than grown
# into it, to stay under its file-budget ceiling: same shape as the verdicts still there
# (hugepages_boot_verdict, restore_live_state_verdict, reinstall_prefill_verdict) — a simpler
# check could not tell two different histories apart, so the discrimination moved into a
# sourceable file the KVM battery and this fixture suite both drive. Ambient contract: $ROOT from
# lib.sh, plus lib.sh's assert_eq. Each verdict file is sourced for itself inside its own subshell.

echo "== unit: provisioning_ran_verdict — is-active alone can't tell skipped-by-design from never-triggered (#2055 G3) =="
# tests/os/run.sh's restore leg cannot be driven from here (it needs a real KVM guest), but the
# verdict is pure text-matching over four already-observed strings (two ActiveState reads, two
# ConditionResult reads) — pulled into tests/os/provisioning-settled.sh for exactly that reason,
# the same discrimination #1212 needed for hugepages. The case that matters is the second pair
# below: firstboot and boot BOTH read `inactive` (the exact "units: inactive inactive" row #2055
# names) but now fails instead of reading as a finished provisioning, because neither unit's
# ConditionResult says it ran.
# Mutation run: drop the ConditionResult check and fall back to judging ActiveState alone -> the
# "neither unit ran" case flips from fail to pass, silently reintroducing the #2055 G3 gap.
prv() { # <firstboot-active> <boot-active> <firstboot-ran> <boot-ran> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/provisioning-settled.sh"
        provisioning_ran_verdict "$1" "$2" "$3" "$4"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "firstboot skipped, boot ran (the normal provisioned case): passes" \
    "$(prv inactive active no yes)" \
    "0 one provisioning unit ran this boot (firstboot: inactive/ran=no, boot: active/ran=yes)"
assert_eq "firstboot ran, boot skipped (the normal unprovisioned case): passes" \
    "$(prv inactive inactive yes no)" \
    "0 one provisioning unit ran this boot (firstboot: inactive/ran=yes, boot: inactive/ran=no)"
assert_eq "both inactive, neither ran: fails — the #2055 G3 case is-active alone missed" \
    "$(prv inactive inactive no no)" \
    "1 neither provisioning unit ran this boot (firstboot ConditionResult: no, boot: no) — is-active alone cannot tell a correctly-skipped unit from one that never got the chance"
assert_eq "unreadable ConditionResult: fails, names it unreadable" \
    "$(prv inactive inactive "" "")" \
    "1 neither provisioning unit ran this boot (firstboot ConditionResult: unreadable, boot: unreadable) — is-active alone cannot tell a correctly-skipped unit from one that never got the chance"
unset -f prv

echo "== unit: config-reset waits for systemd condition evaluation before reading the result (#2836) =="
condition_wait_case() (
    # shellcheck disable=SC1091
    source "$ROOT/tests/os/provisioning-settled.sh"
    UNIT_CONDITION_ATTEMPTS=3 UNIT_CONDITION_POLL_S=0
    calls="$SANDBOX/condition-calls"
    printf '0\n' >"$calls"
    _ssh() {
        case "$*" in
        *ConditionTimestampMonotonic*)
            read -r count <"$calls"
            printf '%s\n' "$((count + 1))" >"$calls"
            if [ "$count" -lt 2 ]; then printf '0\n'; else printf '42\n'; fi
            ;;
        *ConditionResult*) printf 'yes\n' ;;
        esac
    }
    rc=0
    wait_unit_condition_evaluated pithead-firstboot && unit_ran_this_boot pithead-firstboot || rc=$?
    read -r count <"$calls"
    printf '%s %s ' "$rc" "$count"
    _ssh() { printf '0\n'; }
    wait_unit_condition_evaluated pithead-boot
    printf '%s\n' "$?"
)
wait_result=$(condition_wait_case)
assert_eq "delayed condition evaluation permits the result probe; an unevaluated unit times out" "$wait_result" "0 3 1"
stalled_condition_case() (
    # shellcheck disable=SC1091
    source "$ROOT/tests/os/provisioning-settled.sh"
    UNIT_CONDITION_ATTEMPTS=2 UNIT_CONDITION_POLL_S=0 SSH_PROBE_TIMEOUT=0.1
    calls="$SANDBOX/stalled-condition-calls"
    printf '0\n' >"$calls"
    _ssh() {
        read -r n <"$calls"
        printf '%s\n' "$((n + 1))" >"$calls"
        printf '%s\n' "${SSH_TIMEOUT:-5400}" >"$calls.limit"
        timeout "${SSH_TIMEOUT:-5400}" sleep 1
    }
    rc=0
    wait_unit_condition_evaluated pithead-boot || rc=$?
    read -r n <"$calls"
    read -r limit <"$calls.limit"
    printf '%s %s %s\n' "$rc" "$n" "$limit"
)
assert_eq "a stalled systemctl reply is bounded on every poll" "$(stalled_condition_case)" "1 2 0.1"
unset -f stalled_condition_case
# Drive the reset row's actual probe block: each result read must follow both evaluations.
reset_probe=$(sed -n '/^    # Two systemd conditions in opposition/,/^    unit_ran_this_boot pithead-boot && boot_ran=yes/p' "$ROOT/tests/os/phases/reset-config.sh")
reset_probe_case() (
    # shellcheck disable=SC1091
    source "$ROOT/tests/os/provisioning-settled.sh"
    UNIT_CONDITION_ATTEMPTS=3 UNIT_CONDITION_POLL_S=0
    timeout_boot="${1:-0}"
    trace="$SANDBOX/reset-condition-trace"
    printf '' >"$trace"
    printf '0\n' >"$trace.f"
    printf '0\n' >"$trace.b"
    _ssh() {
        case "$*" in
        *ConditionTimestampMonotonic*pithead-firstboot*)
            read -r n <"$trace.f"
            printf '%s\n' "$((n + 1))" >"$trace.f"
            printf ' F%s' "$n" >>"$trace"
            if [ "$n" -eq 0 ]; then printf '0\n'; else printf '42\n'; fi
            ;;
        *ConditionTimestampMonotonic*pithead-boot*)
            read -r n <"$trace.b"
            printf '%s\n' "$((n + 1))" >"$trace.b"
            printf ' B%s' "$n" >>"$trace"
            if [ "$n" -eq 0 ] || [ "$timeout_boot" = 1 ]; then printf '0\n'; else printf '42\n'; fi
            ;;
        *ConditionResult*pithead-firstboot*)
            printf ' RF' >>"$trace"
            printf 'yes\n'
            ;;
        *ConditionResult*pithead-boot*)
            printf ' RB' >>"$trace"
            printf 'no\n'
            ;;
        esac
    }
    bad() { printf 'BAD %s\n' "$1"; }
    eval "$reset_probe"
    printf '%s %s%s\n' "$fb_ran" "$boot_ran" "$(cat "$trace")"
)
assert_eq "reset waits for both units before either result probe" "$(reset_probe_case)" "yes no F0 F1 B0 B1 RF RB"
assert_eq "reset names the unit whose condition never evaluated" "$(reset_probe_case 1)" \
    "BAD config-reset timed out waiting for pithead-boot conditions to be evaluated"
unset -f reset_probe_case
unset -f condition_wait_case

echo "== unit: provisioning_setup_failed — a settled provisioning is not a succeeded one (#2725) =="
# Job 1194: firstboot ended `failed` (tor unhealthy), provisioning_settled accepted that as
# terminal, and the restore leg backed up a failed stack. Mutation run: return 1 unconditionally
# -> the first case flips and the leg goes back to taking its backup over a dead setup.
psf() { # <four provisioning_units fields> -> 0 when the restore leg must stop
    (
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/provisioning-settled.sh"
        fields=("$@")
        _ssh() { printf '%s\n' "${fields[@]}"; } # the guest's four systemctl answers, one per line
        provisioning_setup_failed && echo stop || echo go
    )
}
assert_eq "firstboot ran and failed (job 1194): stop" "$(psf failed inactive yes no)" "stop"
assert_eq "boot ran and failed: stop" "$(psf inactive failed no yes)" "stop"
assert_eq "firstboot ran and finished: go" "$(psf inactive inactive yes no)" "go"
assert_eq "boot ran and is active: go" "$(psf inactive active no yes)" "go"
unset -f psf

echo "== unit: secure_boot_boot_verdict — Secure Boot ON is measured, not left an unread flag (#2055 G2) =="
# tests/os/run.sh's phase_boot second guest cannot be driven from here (it needs real KVM +
# OVMF secure-boot firmware), but the verdict is pure text-matching over two already-observed
# signals (did virt-install define the guest, did a userspace banner appear, and image version) —
# pulled into
# tests/os/secure-boot-boot-verdict.sh for exactly that reason. The case that matters is the
# second pair below: a guest that DEFINED successfully but never reached userspace reports the
# signing gap without failing the phase for 2.0.0. Later versions require signing, so the same
# measured non-boot fails and the deferral cannot hide a regression.
sbv() { # <virt-install-defined> <userspace-banner-seen> <image-version> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/secure-boot-boot-verdict.sh"
        secure_boot_boot_verdict "$1" "$2" "$3"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "guest defined + reaches userspace under SB: passes" \
    "$(sbv 1 1 2.0.0)" \
    "0 the image reaches userspace with Secure Boot ON — signing works (or SB was not actually enforced; cross-check the guest's own SecureBoot EFI variable before trusting this as a pass)"
assert_eq "guest defined but never reaches userspace under SB: records the deferred state" \
    "$(sbv 1 0 2.0.0)" \
    "0 the image does NOT reach userspace with Secure Boot ON (pithead#2187: shim-signed is the only signed link in the chain — grub-efi-amd64 and the kernel ship unsigned) — measured, deferred past 2.0.0 to v2.x - post-GA"
assert_eq "guest defined but never reaches userspace after signing is required: fails" \
    "$(sbv 1 0 2.0.1)" \
    "1 the image does NOT reach userspace with Secure Boot ON — signing is required, so this is a regression"
assert_eq "virt-install could not even define the guest: fails, names it unmeasured (a possible bench firmware gap)" \
    "$(sbv 0 0 2.0.0)" \
    "1 could not even DEFINE a Secure-Boot-enabled guest (no matching OVMF secure-boot firmware on this host?) — Secure Boot is UNMEASURED here, not proven either way; check for a bench firmware gap before reading this as a product defect"
unset -f sbv

echo "== unit: fault_boot_verdict — BRICKED only when the serial shows no GRUB, kernel or login (#2381) =="
# bench-ci job 101's fault phase reported A1 as BRICKED (disqualifying) while its own
# pithead-os-serial.log.failed showed GRUB naming the current slot and "pithead login:" ten
# seconds later — the SSH probe failed, not the boot. tests/os/fault-boot-verdict.sh reads the
# serial console from the byte offset the power cycle started at and tells the two apart.
# Mutation run: drop the offset and let it scan the whole log -> the earlier boot's own GRUB/login
# lines "prove" a boot that never happened after THIS power cut, silently hiding a real brick.
FBV="$SANDBOX/fault-boot-verdict"
mkdir -p "$FBV"
# shellcheck source=tests/os/fault-boot-verdict.sh
source "$ROOT/tests/os/fault-boot-verdict.sh"
printf 'GNU GRUB  version 2.06\nLoading Linux 6.1.0 ...\nDebian GNU/Linux 12 pithead ttyS0\npithead login: ' \
    >"$FBV/booted"
verdict=$(fault_boot_verdict "$FBV/booted" 0)
assert_rc "a serial log naming GRUB, kernel and login is not BRICKED" "$?" "0"
assert_contains "…and says the probe failed, not the boot" "$verdict" "the PROBE failed to reach it, not the boot"
printf 'Powering up......\nqemu: no console output\n' >"$FBV/no-boot"
verdict=$(fault_boot_verdict "$FBV/no-boot" 0)
assert_rc "a serial log with no GRUB, kernel or login evidence IS BRICKED" "$?" "1"
assert_contains "…and quotes the serial's last lines" "$verdict" "qemu: no console output"
# Leg C has no power cut: the same QEMU keeps appending, so only bytes after the size mark count
# and the earlier boot's login line must not leak across it.
cp "$FBV/booted" "$FBV/serial"
mark=$(fault_serial_mark "$FBV/serial")
cat "$FBV/no-boot" >>"$FBV/serial"
verdict=$(fault_boot_verdict "$FBV/serial" "$mark")
assert_rc "an earlier boot's login prompt does not mask a real brick after the size mark" "$?" "1"
# #2746: a power-cut leg sets the old console aside while no QEMU holds the file, so the next boot
# is judged from byte 0 whatever the chardev does. Job 220: the restarted guest's console began
# with the very bytes the old one did, so a mark by size or prefix could not find where it started.
# Mutation run: skip the move-and-empty -> the old boot's GRUB and login count for a silent boot.
cp "$FBV/booted" "$FBV/serial"
mark=$(fault_serial_cut "$FBV/serial")
assert_eq "the cut judges the next boot from offset 0" "$mark" "0"
assert_eq "…and keeps the old console at <log>.pre-cut" "$(cat "$FBV/serial.pre-cut")" "$(cat "$FBV/booted")"
cat "$FBV/no-boot" >>"$FBV/serial"
verdict=$(fault_boot_verdict "$FBV/serial" "$mark")
assert_rc "old GRUB and login before the cut do not vouch for a silent boot after it" "$?" "1"
# The same boot printed again after the cut is this boot's own evidence (job 220's case, booted).
cp "$FBV/booted" "$FBV/serial"
mark=$(fault_serial_cut "$FBV/serial")
cat "$FBV/booted" >>"$FBV/serial"
fault_boot_verdict "$FBV/serial" "$mark" >/dev/null
assert_rc "a new boot that prints the old banner byte for byte is judged booted" "$?" "0"
# Operator ruling on #2748: a console that cannot be set aside must stop the leg, never fall back
# to an unproven boundary. Old GRUB and login in the log, the move forced to fail, and nothing a
# boot would print after it. Mutation run: ignore the failed copy -> the leg judges on.
cp "$FBV/booted" "$FBV/serial"
mark=$(
    cp() { return 1; } # the move fails, whoever runs it
    fault_serial_cut "$FBV/serial"
)
assert_rc "a console that cannot be set aside fails the cut" "$?" "1"
assert_eq "…prints no offset to judge from" "$mark" ""
assert_eq "…and leaves the old console where it was" "$(cat "$FBV/serial")" "$(cat "$FBV/booted")"
cat "$FBV/no-boot" >>"$FBV/serial"
verdict=$(fault_boot_verdict "$FBV/serial" "$mark")
assert_rc "an unproven boundary is not judged, never read from byte 0 as booted" "$?" "2"
assert_contains "…and says why" "$verdict" "this boot cannot be judged"
# An offset past the end of a log that shrank since it was taken is just as unproven.
fault_boot_verdict "$FBV/no-boot" 999999 >/dev/null
assert_rc "an offset past the end of a shrunk log is not judged" "$?" "2"
# A console that does not exist yet is a proven boundary for both marks.
rm -f "$FBV/fresh"
assert_eq "an absent log cuts at offset 0" "$(fault_serial_cut "$FBV/fresh")" "0"
assert_eq "an absent log marks offset 0" "$(fault_serial_mark "$FBV/fresh")" "0"
# The phase itself (tests/os/phases/fault.sh) needs a KVM guest, so its wiring is pinned here:
# legs A, B and D set the console aside before restarting and stop when they cannot, leg C stops
# when it cannot read its mark, and all four read exit 2 as neither booted nor BRICKED.
# Mutation run: drop any one leg's `|| {` or `elif [ $? -eq 2 ]` -> a count drops.
assert_eq "the three power-cut legs stop when the console cannot be set aside" \
    "$(grep -cF 'fault_serial_cut "$SERIAL") || {' "$ROOT/tests/os/phases/fault.sh")" "3"
assert_eq "leg C stops when its mark cannot be read" \
    "$(grep -cF 'fault_serial_mark "$SERIAL") || {' "$ROOT/tests/os/phases/fault.sh")" "1"
assert_eq "all four legs report an unjudgeable boot as such" \
    "$(grep -cF 'elif [ $? -eq 2 ]; then' "$ROOT/tests/os/phases/fault.sh")" "4"
# Jobs 220 and 129: A1's console held not one byte after the cut, and a discarded `virsh start`
# error could not be told from a brick. Legs A and B stop on a failed start; A, B and D name the
# domain state on a BRICKED row.
assert_eq "legs A and B stop when virsh start fails after the cut" \
    "$(grep -cF 'start_out=$(virsh start "$VM" 2>&1) || {' "$ROOT/tests/os/phases/fault.sh")" "2"
assert_eq "every power-cut BRICKED row names the domain state" \
    "$(grep -cF -- '— domain: $(virsh domstate "$VM" --reason' "$ROOT/tests/os/phases/fault.sh")" "3"
# #2746: the failed boot's console is kept before the leg returns and the next phase clobbers it.
# Mutation run: drop the copy -> no .failed file.
rm -f "$FBV/no-boot.failed"
fault_boot_verdict "$FBV/no-boot" 0 >/dev/null
assert_eq "the judged console is kept at <log>.failed" "$(cat "$FBV/no-boot.failed" 2>/dev/null)" "$(cat "$FBV/no-boot")"
# A copy that fails says so in the verdict instead of leaving the evidence silently missing.
# (A missing log fails the copy for root too, where a read-only directory would not.)
verdict=$(fault_boot_verdict "$FBV/absent" 0)
assert_contains "a console that cannot be kept is named in the verdict" "$verdict" "could not keep the console at $FBV/absent.failed"
# Jobs 220, 129 and 224: `virsh destroy` on a guest busy writing its spare slot failed, the
# discarded failure left the domain up, and `virsh start` answered "Domain is already active".
# fault_power_cut retries until the domain reports "shut off", or says it never did.
# Mutation run: return after one destroy -> the "third try" row reads 1, not 0.
pcut() { # <tries until the domain is off, 0 = never> -> "<rc> <destroy calls> <output>"
    (
        want="$1"
        echo 0 >"$FBV/destroys" # a file: fault_power_cut calls virsh inside $(...)
        virsh() {
            local n
            n=$(cat "$FBV/destroys")
            case "$1" in
            destroy)
                echo $((n + 1)) >"$FBV/destroys"
                [ "$want" -gt 0 ] && [ $((n + 1)) -ge "$want" ] && return 0
                echo "error: Failed to terminate process: Device or resource busy" >&2
                return 1
                ;;
            domstate) if [ "$want" -gt 0 ] && [ "$n" -ge "$want" ]; then echo "shut off"; else echo running; fi ;;
            esac
        }
        sleep() { :; }
        out=$(fault_power_cut vm)
        rc=$?
        printf '%s %s %s' "$rc" "$(cat "$FBV/destroys")" "$out"
    )
}
assert_eq "a domain off after the first destroy: one call" "$(pcut 1)" "0 1 "
assert_eq "a domain that takes three destroys is waited for" "$(pcut 3)" "0 3 "
assert_eq "a domain that never goes off fails the cut with virsh's word" "$(pcut 0)" \
    "1 6 error: Failed to terminate process: Device or resource busy"
assert_eq "all three power-cut legs cut through fault_power_cut and stop when it fails" \
    "$(grep -cF 'verdict=$(fault_power_cut "$VM") || {' "$ROOT/tests/os/phases/fault.sh")" "3"
unset -f pcut
unset -f fault_power_cut fault_serial_cut fault_serial_mark fault_serial_since
unset -f fault_boot_verdict
rm -rf "$FBV"

echo "== unit: m10_height_verdict — a readable lower height is chain loss, apart from an unreadable RPC (#2557) =="
# bench-ci job 840 failed M10.1 with "before: 56540, after: 56040" under one message that also
# covered an unreadable RPC. The leg now flushes the guest after the pre-cut read, so the verdict
# can hold the node to that persisted height and name which of the two failures it saw.
# Mutation run: drop the lower-height branch -> job 840's readable 56040 passes as a recovery.
mhv() { # <persisted-before> <after> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/m10-height-verdict.sh"
        m10_height_verdict "$1" "$2"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "job 840's readable lower height fails as lost persisted blocks" \
    "$(mhv 56540 56040)" \
    "1 monerod LOST 500 persisted blocks across the cut (persisted before: 56540, after: 56040)"
assert_eq "an unreadable post-cut RPC fails as unreadable, not as chain loss" \
    "$(mhv 56540 "")" \
    "1 monerod RPC unreadable after the cut (persisted before: 56540, after: unreadable)"
assert_eq "an unreadable pre-cut height fails before any comparison" \
    "$(mhv "" 56540)" \
    "1 could not read a persisted monerod height before the cut (read: unreadable)"
assert_eq "the same height passes" \
    "$(mhv 56540 56540)" \
    "0 monerod reports height 56540, at or past the persisted pre-cut height 56540"
assert_eq "a higher height passes" \
    "$(mhv 56540 56600)" \
    "0 monerod reports height 56600, at or past the persisted pre-cut height 56540"
unset -f mhv

echo "== structure: the provision phase settles provisioning before its day-two legs (#2648) =="
# dashboard and caddy run while the wizard's `up` still waits on tor's healthcheck, so the podman ps
# row alone let job 944's control legs race an unfinished provisioning. Mutation runs: move or drop
# the provisioning_settled call, negate it, drop the #2725 failed-setup guard, or move the `return 1`
# out of its else branch -> red.
PI_ORDER=$(awk '
    /ok "stack containers are running/ { up = NR }
    up && !settled && /^ *if provisioning_settled [0-9]+ && ! provisioning_setup_failed; then/ { settled = NR }
    settled && !closed && /^ *else$/ { otherwise = NR }
    otherwise && !aborts && !closed && /^ *return 1$/ { aborts = NR }
    settled && !closed && /^ *fi$/ { closed = NR }
    /^ *phase_provision_control_regressions / { control = NR }
    END { print (up && aborts && control && settled < control ? "settled-first" : "control-first or missing") }
' "$ROOT/tests/os/phases/provision-initial.sh")
assert_eq "provision settles provisioning after the stack row and before the control legs" "$PI_ORDER" "settled-first"
unset PI_ORDER

echo "== unit: boot gate progress — elapsed minutes every sixth failed pass =="
# shellcheck disable=SC2034,SC2154 # variables assigned/read by the extracted production loop
boot_progress_case() (
    unset SECONDS
    SECONDS=600
    gate_doctor_ran=0 gate_advisory="" hold_chain=0 OS_INFLIGHT="$SANDBOX/absent-inflight"
    gate_target=fixture gate_resolve_args=()
    probe_seconds="$2"
    curl() { echo "503 $probe_seconds"; }
    pass_at="$1"
    gate_ready() { ((SECONDS += probe_seconds, gate_attempt == pass_at)); }
    sleep() { SECONDS=$((SECONDS + $1)); }
    boot_gate_passed() { :; }
    rauc() { :; }
    timeout() { :; }
    gate_loop=$(sed -n '/^gate_wait_started=/,/^done$/p' "$ROOT/os/overlay/pithead-boot")
    gate_loop=${gate_loop//\/dev\/tty1/${3:-$SANDBOX/boot-progress-vga}}
    eval "${gate_loop//\/dev\/ttyS0/$SANDBOX/boot-progress-serial}"
)
touch "$SANDBOX/boot-progress-vga" "$SANDBOX/boot-progress-serial"
progress_text='Leave it powered on: if an update never becomes healthy, the machine goes back to the previous version by itself.'
assert_not_contains "passing on round six prints no progress" "$(boot_progress_case 6 0)" "still starting"
assert_eq "early success leaves both consoles silent" "$(wc -c <"$SANDBOX/boot-progress-vga"):$(wc -c <"$SANDBOX/boot-progress-serial")" "0:0"
progress_out=$(boot_progress_case 13 0)
assert_eq "twelve failures print twice" "$(printf '%s\n' "$progress_out" | grep -c 'still starting')" "2"
assert_contains "first progress minute and recovery text" "$progress_out" "Pithead is still starting (1 of about 16 minutes). $progress_text"
assert_contains "second progress minute" "$progress_out" "still starting (2 of about 16 minutes)"
assert_eq "VGA and serial receive the journal's progress line" "$(cmp -s "$SANDBOX/boot-progress-vga" "$SANDBOX/boot-progress-serial" && grep -Fxq "pithead-boot: Pithead is still starting (2 of about 16 minutes). $progress_text" "$SANDBOX/boot-progress-vga" && echo delivered)" "delivered"
mkdir "$SANDBOX/boot-progress-bad"
assert_contains "a failed console write cannot hold a healthy gate" "$(boot_progress_case 7 0 "$SANDBOX/boot-progress-bad")" "booted slot committed"
assert_eq "the other console receives fresh progress" "$(cat "$SANDBOX/boot-progress-serial")" "pithead-boot: Pithead is still starting (1 of about 16 minutes). $progress_text"
assert_contains "slow probes count real elapsed time, excluding earlier boot work" "$(boot_progress_case 7 20)" "still starting (3 of about 16 minutes)"
unset -f boot_progress_case
unset progress_text progress_out
