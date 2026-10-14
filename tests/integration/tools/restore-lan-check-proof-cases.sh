# shellcheck shell=bash
: "${IT_PASS:?source via selftest-e2e-restore-proof.sh}"
lan_check_restore() { # <before> <now> [sticky]
    (
        # shellcheck disable=SC2034 # read by the sourced restore function
        LAN_CHECK_BEFORE="$1" UNITS="$2" STICKY="${3:-0}" removals=0
        ok() { :; }
        warn() { :; }
        on_bench() {
            case "$1" in
            *"disable --now pithead-lan.timer"*)
                removals=$((removals + 1))
                [ "$STICKY" = 1 ] || UNITS=absent
                ;;
            esac
        }
        egress_boot_unit_state() { echo "$UNITS"; }
        restore_lan_check_units
        echo "$? $UNITS $removals"
    )
}
assert_eq "a LAN check pair added by the run is removed" "$(lan_check_restore absent present)" "0 absent 1"
assert_eq "a pre-existing LAN check pair is kept" "$(lan_check_restore present present)" "0 present 0"
assert_eq "a LAN check pair left behind fails the restore" "$(lan_check_restore absent present 1)" "1 present 1"
assert_eq "an unknown LAN check baseline fails without removing it" "$(lan_check_restore '' present)" "1 present 0"
