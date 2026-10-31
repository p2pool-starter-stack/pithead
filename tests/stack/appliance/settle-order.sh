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
# The k-th `podman ps` listing's loop closes with `done`; the first code line after it must be the
# guarded wait, and its else branch must leave the phase. Prints settled-first or what came first.
settle_site() { # $1 phase file, $2 which listing
    awk -v want="$2" '
        /podman ps --format/ && !/^ *#/ { rows++ }
        rows == want && /^ *done$/ && !seen { seen = 1; next }
        seen && !done && !/^ *#/ && /_ssh|curl|phase_|assert_|provisioning_settled|_monerod_height|_marker|virsh/ {
            done = 1
            if ($0 ~ /^ *if provisioning_settled [0-9]+ && ! provisioning_setup_failed; then/) guard = 1
            else first = $0
            next
        }
        guard && /^ *else$/ { inelse = 1; next }
        guard && inelse && /^ *return( 1)?$/ { aborts = 1; exit }
        guard && inelse && /^ *fi$/ { exit }
        END { print (guard && aborts ? "settled-first" : "first guest line: " first) }
    ' "$ROOT/tests/os/phases/$1.sh"
}
for _site in reset-config:1 reset:1 update-dashboard:1 media:1 crossupdate:1 crossupdate:2; do
    assert_eq "${_site%%:*} listing ${_site##*:} is followed by the guarded provisioning wait that aborts the phase" \
        "$(settle_site "${_site%%:*}" "${_site##*:}")" "settled-first"
done
unset -f settle_site
unset _site
