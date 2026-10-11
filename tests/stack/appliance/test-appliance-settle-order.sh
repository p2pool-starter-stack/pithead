# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Tier-1 structure pins for #2661: every tests/os phase that lists the stack after a boot, reset or
# slot swap waits on provisioning_settled before its day-two legs. The provision phase and its
# reboot leg are pinned by ordering: the provision phase here, its reboot leg in
# test-appliance-boot-verdicts.sh, which sources this file.
# dashboard and caddy run while the wizard's `up` still waits on tor's healthcheck, so the podman ps
# row alone let job 944's control legs race an unfinished provisioning. Mutation runs: move or drop
# the provisioning_settled call, negate it, drop the #2725 failed-setup guard, or move the `return 1`
# out of its else branch -> red.
echo "== structure: the provision phase settles provisioning before its day-two legs (#2648) =="
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
for _phase in reset-config reset update-dashboard media; do
    assert_eq "$_phase waits for provisioning to settle after its stack row" \
        "$(awk '/podman ps --format/ { row = 1 } row && /provisioning_settled [0-9]+/ { print "settled"; exit }' "$ROOT/tests/os/phases/$_phase.sh")" "settled"
done
assert_eq "crossupdate waits for provisioning to settle at both stack rows" \
    "$(grep -c 'provisioning_settled [0-9]' "$ROOT/tests/os/phases/crossupdate.sh")" "2"
unset _phase
