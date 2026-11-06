# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
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
settle_site() {
    awk -v want="$2" '
        /podman ps --format/ && !/^ *#/ { rows++ }
        rows == want && /^ *done$/ && !seen { seen = 1; next }
        seen && !done && !/^ *#/ && /_ssh|curl|phase_|assert_|provisioning_settled|_monerod_height|_marker|virsh|m10_recovered/ {
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
for _site in reset-config:1 reset:1 update-dashboard:1 media:1 crossupdate:1 crossupdate:2 provision-power-cut:2 setup-defaults:1; do
    assert_eq "${_site%%:*} listing ${_site##*:} is followed by the guarded provisioning wait that aborts the phase" \
        "$(settle_site "${_site%%:*}" "${_site##*:}")" "settled-first"
done
unset -f settle_site
unset _site
