# shellcheck shell=bash
# Sourced by selftest-e2e-restore-proof.sh; the timer and its triggered service are separate units.
echo "== egress check units restore independently (#2599) =="
check_restore() { # <timer before> <service before> <timer now> <service now> [sticky timer] [sticky service]
    (
        # shellcheck disable=SC2034  # consumed by restore_egress_check_units from restore-proof.sh
        EGRESS_CHECK_BEFORE="$1" EGRESS_CHECK_SERVICE_BEFORE="$2"
        TIMER="$3" CHECK="$4" STICKY_TIMER="${5:-0}" STICKY_CHECK="${6:-0}"
        timer_removals=0 check_removals=0
        ok() { :; }
        warn() { :; }
        step() { :; }
        on_bench() {
            case "$1" in
            *"disable --now pithead-egress.timer"*)
                timer_removals=$((timer_removals + 1))
                [ "$STICKY_TIMER" = 1 ] || TIMER=absent
                ;;
            *"disable --now pithead-egress-check.service"*)
                check_removals=$((check_removals + 1))
                [ "$STICKY_CHECK" = 1 ] || CHECK=absent
                ;;
            *"systemctl cat pithead-egress.timer"*) echo "$TIMER" ;;
            *"systemctl cat pithead-egress-check.service"*) echo "$CHECK" ;;
            *"grep -qw pithead-egress.timer"*) [ "$TIMER" = absent ] ;;
            *"grep -qw pithead-egress-check.service"*) [ "$CHECK" = absent ] ;;
            esac
        }
        restore_egress_check_units
        echo "$? $TIMER/$CHECK $timer_removals/$check_removals"
    )
}
assert_eq "both check units added by the run are removed" "$(check_restore absent absent present present)" "0 absent/absent 1/1"
assert_eq "both pre-existing check units are kept" "$(check_restore present present present present)" "0 present/present 0/0"
assert_eq "pre-existing timer does not shelter a newly added check service" "$(check_restore present absent present present)" "0 present/absent 0/1"
assert_eq "pre-existing check service survives removal of a newly added timer" "$(check_restore absent present present present)" "0 absent/present 1/0"
assert_eq "timer surviving removal fails the restore" "$(check_restore absent absent present present 1)" "1 present/absent 1/1"
assert_eq "check service surviving removal fails the restore" "$(check_restore absent absent present present 0 1)" "1 absent/present 1/1"
assert_eq "unrecorded timer fails while the service is restored" "$(check_restore '' absent present present)" "1 present/absent 0/1"
assert_eq "unrecorded service fails while the timer is restored" "$(check_restore absent '' present present)" "1 absent/present 1/0"
assert_contains "verify_restore_proof runs both check-unit restores" "$(declare -f verify_restore_proof)" "restore_egress_check_units"
assert_contains "e2e.sh records the timer before deploy_branch installs it" "$(cat "$E2E_SRC")" 'EGRESS_CHECK_BEFORE="$(egress_boot_unit_state pithead-egress.timer)"'
assert_contains "e2e.sh records the service before deploy_branch installs it" "$(cat "$E2E_SRC")" 'EGRESS_CHECK_SERVICE_BEFORE="$(egress_boot_unit_state pithead-egress-check.service)"'
assert_contains "restore checks timer wants, not just its file" "$(declare -f restore_boot_unit)" 'timers.target'
