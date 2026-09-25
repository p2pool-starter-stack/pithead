# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The dashboard's view of the Tor-only egress firewall (#2599): a host timer runs the doctor's
# tor_egress_enforced() every two minutes and writes the verdict where the containerised dashboard
# can read it. These pin the units (the timer targets the read-only check, never the boot unit),
# the status file the verb writes, and that up/apply/opt-out/uninstall own the pair under the
# control runner's ownership rule. Self-contained stubs. Sourced by tests/stack/run.sh.

EC="$SANDBOX/egress-check"
mkdir -p "$EC/bin" "$EC/units" "$EC/ctl"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$EC/bin/sudo"
printf '#!/usr/bin/env bash\necho Linux\n' >"$EC/bin/uname"
# systemctl logs every call; `is-active` answers from SYSTEMCTL_ACTIVE (default: not active).
cat >"$EC/bin/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$EC/systemctl.log"
[ "\$1" = is-active ] && exit "\${SYSTEMCTL_ACTIVE:-1}"
exit 0
EOF
chmod +x "$EC"/bin/*
ec_env() { printf 'CONTROL_DIR=%s\nTOR_EGRESS_FIREWALL=%s\n' "$EC/ctl" "${1:-true}" >"$EC/.env"; }
ec_env
ec_run() {
    PITHEAD_ENGINE="${EC_ENGINE:-docker}" PITHEAD_APPLIANCE=0 PITHEAD_UNIT_DIR="$EC/units" \
        PATH="$EC/bin:$PATH" run_sourced "$EC" "$@"
}
EC_SVC="$EC/units/pithead-egress-check.service"
EC_TIMER="$EC/units/pithead-egress.timer"
ec_has() { [ -e "$1" ] && echo present; }

echo "== units: a 2-minute timer on a read-only check, never on the boot unit (#2599) =="
ET=$(run_sourced "$SANDBOX" render_egress_check_timer)
assert_contains "fires two minutes after boot" "$ET" "OnBootSec=2min"
assert_contains "and every two minutes after the last check" "$ET" "OnUnitActiveSec=2min"
assert_contains "targets the check, not pithead-egress.service (the boot unit)" "$ET" "Unit=pithead-egress-check.service"
assert_contains "installed with the timers" "$ET" "WantedBy=timers.target"
ES=$(run_sourced "$SANDBOX" render_egress_check_service /opt/ph podman)
assert_eq "its only ExecStart is the read-only verb (no rule is inserted or deleted)" \
    "$(printf '%s\n' "$ES" | grep '^ExecStart=')" "ExecStart=/opt/ph/pithead egress-status"
assert_contains "pins the engine the install was provisioned with (#2059)" "$ES" "Environment=PITHEAD_ENGINE=podman"
assert_contains "runs from the install" "$ES" "WorkingDirectory=/opt/ph"

echo "== verb: egress-status writes {rc, verdict, checked_at} for the dashboard (#2599) =="
ec_status() { # <rc tor_egress_enforced returns>
    (
        cd "$EC" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        eval "tor_egress_enforced() { return $1; }"
        egress_status
    )
}
EC_FILE="$EC/ctl/results/egress-status.json"
for pair in 0:enforced 1:absent 2:no-tool 3:unreadable 4:jump-missing 5:shadowed; do
    out=$(ec_status "${pair%%:*}")
    assert_eq "each tor_egress_enforced rc prints its verdict" "rc ${pair%%:*}:$out" "rc $pair"
    assert_eq "each rc is written with its verdict" "$(jq -c '[.rc, .verdict]' "$EC_FILE")" \
        "[${pair%%:*},\"${pair#*:}\"]"
done
now=$(date +%s)
assert_eq "checked_at is the write time" "$(jq '.checked_at >= '"$((now - 5))"' and .checked_at <= '"$((now + 5))" "$EC_FILE")" "true"
assert_eq "the dashboard (another uid) can read it" "$(stat -c %a "$EC_FILE" 2>/dev/null || stat -f %Lp "$EC_FILE")" "644"
assert_eq "no temp file is left beside it (written by rename)" "$(find "$EC/ctl/results" -name '.egress-status.*' | wc -l | tr -d ' ')" "0"

echo "== provision: up/apply install and start the pair; re-runs are quiet (#2599) =="
rm -f "$EC/systemctl.log"
ec_run provision_egress_check_units >/dev/null 2>&1
assert_eq "writes the check service" "$(cat "$EC_SVC" 2>/dev/null)" "$(run_sourced "$SANDBOX" render_egress_check_service "$(cd "$EC" && pwd)" docker)"
assert_eq "writes the timer" "$(cat "$EC_TIMER" 2>/dev/null)" "$(run_sourced "$SANDBOX" render_egress_check_timer)"
assert_contains "enables and starts the timer" "$(cat "$EC/systemctl.log")" "enable --now pithead-egress.timer"
rm -f "$EC/systemctl.log"
SYSTEMCTL_ACTIVE=0 ec_run provision_egress_check_units >/dev/null 2>&1
assert_not_contains "a re-run with the same units and the timer active does not reload systemd" \
    "$(cat "$EC/systemctl.log")" "daemon-reload"
assert_contains "up provisions the pair" "$(run_sourced "$SANDBOX" type stack_up)" "provision_egress_check_units"
assert_contains "render (every appliance boot) provisions the pair" "$(run_sourced "$SANDBOX" type render_derived)" "provision_egress_check_units"

echo "== provision: another live install's pair is left alone unless stolen (#2599) =="
mkdir -p "$EC/other"
run_sourced "$SANDBOX" render_egress_check_service "$EC/other" docker >"$EC_SVC"
out=$(ec_run provision_egress_check_units 2>&1)
assert_contains "refuses to repoint a live sibling's pair" "$out" "egress-check:foreign-units"
assert_contains "and leaves it naming the sibling" "$(cat "$EC_SVC")" "ExecStart=$EC/other/pithead egress-status"
ec_run provision_egress_check_units steal >/dev/null 2>&1
assert_contains "upgrade's steal takes it over" "$(cat "$EC_SVC")" "ExecStart=$(cd "$EC" && pwd -P)/pithead egress-status"
run_sourced "$SANDBOX" render_egress_check_service "$EC/gone" docker >"$EC_SVC"
ec_run provision_egress_check_units >/dev/null 2>&1
assert_contains "a pair naming a deleted install is adopted" "$(cat "$EC_SVC")" "ExecStart=$(cd "$EC" && pwd -P)/pithead egress-status"

echo "== provision: opt-out and uninstall remove only this install's pair (#2599) =="
printf '[Unit]\n' >"$EC/units/other.timer"
ec_env false
rm -f "$EC/systemctl.log"
ec_run provision_egress_check_units >/dev/null 2>&1
assert_eq "opting out removes the check service" "$(ec_has "$EC_SVC")" ""
assert_eq "and the timer" "$(ec_has "$EC_TIMER")" ""
assert_contains "and stops it" "$(cat "$EC/systemctl.log")" "disable --now pithead-egress.timer"
assert_eq "another unit is left alone" "$(ec_has "$EC/units/other.timer")" "present"
ec_env true
run_sourced "$SANDBOX" render_egress_check_service "$EC/other" docker >"$EC_SVC"
ec_run remove_egress_check_units >/dev/null 2>&1
assert_eq "removal leaves a live sibling's pair" "$(ec_has "$EC_SVC")" "present"
rm -f "$EC_SVC"
ec_run provision_egress_check_units >/dev/null 2>&1
un_out=$(
    cd "$EC" || exit
    export PITHEAD_ENGINE=docker PITHEAD_APPLIANCE=0 PITHEAD_UNIT_DIR="$EC/units" PATH="$EC/bin:$PATH"
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    detect_os() { :; }
    docker() { :; }
    provision_control_runner() { :; }
    remove_tor_egress_firewall() { :; }
    stack_uninstall -y 2>&1
)
assert_contains "uninstall completes" "$un_out" "Uninstalled."
assert_eq "uninstall removes the check service" "$(ec_has "$EC_SVC")" ""
assert_eq "and the timer" "$(ec_has "$EC_TIMER")" ""
