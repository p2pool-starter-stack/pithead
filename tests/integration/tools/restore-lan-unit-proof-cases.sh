# shellcheck shell=bash
# Sourced by selftest-e2e-restore-proof.sh: the #2749 LAN units' record and restore.
# --- #2749: each LAN unit goes back the way the run found it, on the same model bench ----------------
lan_restore() { # <unit> <before> <unit now> [sticky]
    (
        NAME="$1" UNIT="$3" STICKY="${4:-0}" removals=0
        ok() { :; }
        warn() { :; }
        step() { printf 'step:%s\n' "$1" >&2; }
        on_bench() {
            case "$1" in
            *"disable --now $NAME"*)
                removals=$((removals + 1))
                [ "$STICKY" = 1 ] || UNIT=absent
                ;;
            *"systemctl cat $NAME "*) echo "$UNIT" ;;
            *"show -p Wants"*"multi-user.target"*"grep -qw $NAME"*)
                # A failed lookup, as the shell sees it: a captured `w=$(...) &&` fails; a bare
                # `! systemctl ... | grep` pipeline greps nothing and succeeds.
                if [ "${SHOW_FAILS:-0}" = 1 ]; then [[ "$1" != *'w=$(systemctl show'* ]]; else [ "$UNIT" = absent ]; fi
                ;;
            esac
        }
        restore_lan_unit "$NAME" "$2"
        echo "$? $UNIT $removals"
    )
}
for u in pithead-lan-guard.service pithead-lan-hold.service; do
    assert_eq "$u: a unit this run added is removed, and its absence and wants proven" "$(lan_restore "$u" absent present)" "0 absent 1"
    assert_eq "$u: a unit the baseline already had is left alone" "$(lan_restore "$u" present present)" "0 present 0"
    assert_eq "$u: a unit that survives the removal fails the restore proof" "$(lan_restore "$u" absent present 1)" "1 present 1"
    assert_eq "$u: an unrecorded baseline fails closed and removes nothing" "$(lan_restore "$u" "" present)" "1 present 0"
    assert_eq "$u: a wants lookup that fails is not proof of absence" "$(SHOW_FAILS=1 lan_restore "$u" absent present)" "1 absent 1"
done
# The lookup itself, run by a real shell against a stub systemctl: a failed read of a present unit
# is unknown, which the restore refuses and removes nothing for (#2749).
unit_state_with() { # <systemctl stub body> -> what egress_boot_unit_state prints
    (
        d=$(mktemp -d)
        printf '#!/usr/bin/env bash\n%s\n' "$1" >"$d/systemctl" && chmod +x "$d/systemctl"
        on_bench() { PATH="$d:$PATH" bash -c "$1"; }
        egress_boot_unit_state pithead-lan-guard.service
        rm -rf "$d"
    )
}
assert_eq "a unit systemd shows is present" "$(unit_state_with 'exit 0')" "present"
assert_eq "a unit systemd reports not-found is absent" "$(unit_state_with '[ "$1" = show ] && echo not-found; [ "$1" = show ]')" "absent"
assert_eq "a failed lookup of a present unit is unknown, not absent" "$(unit_state_with 'exit 1')" ""
assert_eq "...and the restore then refuses and removes nothing" \
    "$(lan_restore pithead-lan-guard.service "$(unit_state_with 'exit 1')" present)" "1 present 0"
assert_contains "verify_restore_proof restores both LAN units" "$(declare -f verify_restore_proof)" \
    'restore_lan_unit pithead-lan-hold.service "$HOLD_UNIT_BEFORE"'
assert_contains "e2e.sh records both before deploy_branch installs them" "$(cat "$E2E_SRC")" \
    'LAN_UNIT_BEFORE="$(egress_boot_unit_state pithead-lan-guard.service)" HOLD_UNIT_BEFORE="$(egress_boot_unit_state pithead-lan-hold.service)"'
