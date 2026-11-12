# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The /data migration floor after a data_migration update that FAILED its gate (#1393). os-update
# raises the floor at install time, before the migration runs; the migration hold (#851) then
# keeps the chain services down until the slot commits, so a slot that fails its gate falls back
# with the data untouched — and, before this, with the floor left raised over it, every later
# os-update below that floor refused with "/data was migrated forward" as fact. Three pieces:
# the raise now records the floor it replaces (or `none`) in `.os-data-floor.prev` BEFORE
# raising; pithead-boot's fallback boot puts the floor back from that record and ONLY from a
# record (with none the floor stays — never lowered without one); and the version guard, on a
# floor above the running version, refuses with the true premise and the open route instead of
# naming a reset. The boot half is a sourceable function driven here with files in a sandbox,
# the same shape as os_update_rollback_verdict; its two call sites sit below the sourcing
# boundary and are asserted by the script's text. Sourced by tests/stack/run.sh.

echo "== unit: os_raise_data_floor records the floor it replaces BEFORE raising (#1393) =="
DF="$SANDBOX/data-floor"
rm -rf "$DF"
mkdir -p "$DF/bin"
printf '#!/bin/sh\nexit 0\n' >"$DF/bin/sync"
chmod +x "$DF/bin/sync"
raise() { # <existing floor, or ABSENT> <new floor> -> "floor=<v|absent> prev=<v|absent>"
    rm -rf "$DF/floor" "$DF/floor.prev"
    [ "$1" = ABSENT ] || printf '%s\n' "$1" >"$DF/floor"
    (
        # shellcheck disable=SC1090
        source "$STACK"
        PATH="$DF/bin:$PATH"
        PITHEAD_DATA_FLOOR_FILE="$DF/floor" os_raise_data_floor "$2"
    ) 2>/dev/null
    printf 'floor=%s prev=%s' "$(tr -d ' \n' 2>/dev/null <"$DF/floor" || echo absent)" \
        "$(tr -d ' \n' 2>/dev/null <"$DF/floor.prev" || echo absent)"
}
assert_eq "no floor yet: the raise lands and the record says none" "$(raise ABSENT 1.17.0)" "floor=1.17.0 prev=none"
assert_eq "an earlier floor: the raise lands and the record keeps the earlier value" "$(raise 1.10.0 1.17.0)" "floor=1.17.0 prev=1.10.0"
# A bundle floor at or below the current one raises nothing — the record is still written, so the
# fallback boot of THIS install finds one (restoring it is a no-op, which is the point).
assert_eq "a no-op raise still records the floor as it stands" "$(raise 1.17.0 1.10.0)" "floor=1.17.0 prev=1.17.0"
# Written FIRST: with the floor path unwritable (a directory in its place) the record is there
# anyway, so a crash between the two writes leaves a record equal to the live floor.
mkdir -p "$DF/floor-dir"
rm -f "$DF/floor-dir.prev"
(
    # shellcheck disable=SC1090
    source "$STACK"
    PATH="$DF/bin:$PATH"
    PITHEAD_DATA_FLOOR_FILE="$DF/floor-dir" os_raise_data_floor 1.17.0
) 2>/dev/null
assert_eq "the record is written before the raise (floor unwritable, record present)" \
    "$(tr -d ' \n' 2>/dev/null <"$DF/floor-dir.prev" || echo absent)" "none"
unset -f raise

echo "== unit: restore_data_floor_after_fallback — the fallback boot puts the floor back from the record, and only from a record (#1393) =="
BD="$SANDBOX/data-floor-boot"
fb() { # <marker: ABSENT|version> <record: ABSENT|EMPTY|none|version> <floor: ABSENT|version>
    #    -> "floor=.. prev=.. marker=.. said=<restored|nothing>"
    rm -rf "$BD"
    mkdir -p "$BD/bin"
    cp "$STACK" "$BD/pithead"
    printf 'rauc.slot=A\n' >"$BD/cmdline"
    printf '#!/bin/sh\nexit 0\n' >"$BD/bin/sync"
    cat >"$BD/bin/rauc" <<'EOF'
#!/usr/bin/env bash
case "$*" in
'status --output-format=json') printf '{"slots":[{"rootfs.0":{"state":"booted","bootname":"A","boot_status":"%s"}}]}\n' "$FLOOR_BOOT_STATUS" ;;
'status mark-bad other') exit "$FLOOR_DISARM_RC" ;;
*) exit 1 ;;
esac
EOF
    chmod +x "$BD/bin/rauc" "$BD/bin/sync"
    [ "$1" = ABSENT ] || printf '%s\n' "$1" >"$BD/.os-migration-pending"
    case "$2" in
    ABSENT) ;;
    EMPTY) : >"$BD/.os-data-floor.prev" ;;
    *) printf '%s\n' "$2" >"$BD/.os-data-floor.prev" ;;
    esac
    [ "$3" = ABSENT ] || printf '%s\n' "$3" >"$BD/.os-data-floor"
    local out
    out=$(
        cd "$BD" || exit
        export PATH="$BD/bin:$PATH" PITHEAD_CMDLINE="$BD/cmdline"
        export FLOOR_BOOT_STATUS="${4:-good}" FLOOR_DISARM_RC="${5:-0}"
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        restore_data_floor_after_fallback
    )
    local said=nothing
    case "$out" in *"floor is back to"*) said=restored ;; esac
    printf 'floor=%s prev=%s marker=%s said=%s' \
        "$(tr -d ' \n' 2>/dev/null <"$BD/.os-data-floor" || echo absent)" \
        "$([ -f "$BD/.os-data-floor.prev" ] && echo present || echo absent)" \
        "$([ -f "$BD/.os-migration-pending" ] && echo present || echo absent)" "$said"
}
assert_eq "fallback with a record: the floor goes back to the recorded value, marker and record consumed" \
    "$(fb 1.17.0 1.10.0 1.17.0)" "floor=1.10.0 prev=absent marker=absent said=restored"
assert_eq "fallback with a 'none' record: the floor is removed (no earlier migration)" \
    "$(fb 1.17.0 none 1.17.0)" "floor=absent prev=absent marker=absent said=restored"
# The fail-safe direction, the load-bearing clause: a box whose failed install predates the
# record has none, and its floor is NOT lowered on a guess. The stale marker still goes.
assert_eq "fallback with NO record: the floor stays exactly as it is, the stale marker goes" \
    "$(fb 1.17.0 ABSENT 1.17.0)" "floor=1.17.0 prev=absent marker=absent said=nothing"
assert_eq "fallback with an EMPTY record: the floor and protection stay" \
    "$(fb 1.17.0 EMPTY 1.17.0)" "floor=1.17.0 prev=present marker=present said=nothing"
assert_eq "fallback before source commitment retains the floor and protection" \
    "$(fb '1.17.0|B' 1.10.0 1.17.0 bad)" "floor=1.17.0 prev=present marker=present said=nothing"
assert_eq "failed candidate disarm retains the floor and protection" \
    "$(fb '1.17.0|B' 1.10.0 1.17.0 good 1)" "floor=1.17.0 prev=present marker=present said=nothing"
assert_eq "no marker: not a fallback boot, nothing is touched" \
    "$(fb ABSENT 1.10.0 1.17.0)" "floor=1.17.0 prev=present marker=absent said=nothing"
unset -f fb
rm -rf "$BD"

echo "== static: fallback cleanup follows durable commitment and held commits consume both records =="
BOOT="$ROOT/os/overlay/pithead-boot"
hold_else=$(awk '/^case "\$migration_rc" in$/{f=1} f&&/^esac$/{print; exit} f' "$BOOT")
assert_not_contains "the hold decision defers fallback cleanup until commitment" "$hold_else" "restore_data_floor_after_fallback"
assert_contains "a non-matching marker leaves chain services unheld" "$hold_else" "0) hold_chain=1 ;;
1) ;;"
commit_cleanup=$(awk '/^    if \[ "\$gate_pass" = 1 \]; then$/{f=1} f&&/stack is serving/{exit} f' "$BOOT")
assert_contains "the coordinator commits durably before fallback cleanup" "$commit_cleanup" 'rauc status mark-good && sync || fail_boot'
assert_contains "fallback cleanup is reached after the successful commit" "$commit_cleanup" 'boot_gate_passed
        commit_config_stamp
        [ "$hold_chain" != 0 ] || restore_data_floor_after_fallback "$migration_fingerprint"'
assert_contains "the shared commit cleanup removes and syncs both records" "$(cat "$BOOT")" \
    '            clear) rm -f "$(os_migration_marker_file)" "$(os_data_floor_file).prev" && sync || exit 1 ;;'
assert_contains "held coordinator release uses durable record cleanup" "$(cat "$BOOT")" '    clear_migration_hold "$@" || return 1'
assert_contains "the rig uses the same cleanup after commitment" "$(cat "$BOOT")" \
    'if [ "$hold_chain" = 1 ]; then clear_migration_hold "$migration_fingerprint"; else restore_data_floor_after_fallback "$migration_fingerprint"; fi'

echo "== unit: os_update_version_guard — a floor ABOVE the running version refuses with the true premise, and the forward route is open (#1393) =="
guard() { # <running version> <floor, or ABSENT> <bundle version> -> the refusal, or empty
    rm -f "$DF/gfloor"
    [ "$2" = ABSENT ] || printf '%s\n' "$2" >"$DF/gfloor"
    (
        cd "$DF" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        PITHEAD_VERSION="$1" PITHEAD_DATA_FLOOR_FILE="$DF/gfloor" os_update_version_guard "$3" 0
    ) 2>/dev/null
}
out=$(guard 1.17.0 2.0.0 1.10.0)
assert_contains "floor above running, bundle below: the refusal names the failed migrating update" "$out" "failed its gate and fell back before its migration ran"
assert_contains "...and the other reading, a slot installed outside pithead" "$out" "installed outside pithead below migrated data"
assert_contains "...and says the forward route is open" "$out" "the floor version or newer installs"
assert_contains "...and says nothing needs resetting or restoring" "$out" "Nothing needs resetting or restoring"
assert_not_contains "...never claims the data WAS migrated" "$out" "migrated forward"
assert_not_contains "...never names a factory reset" "$out" "factory reset"
assert_eq "floor above running, bundle AT the floor: installs (the forward route)" "$(guard 1.17.0 2.0.0 2.0.0)" ""
assert_eq "floor above running, bundle above the floor: installs" "$(guard 1.17.0 2.0.0 2.1.0)" ""
assert_contains "floor above running, unstamped bundle: still the true premise, fail-closed" "$(guard 1.17.0 2.0.0 "")" "failed its gate"
# Controls: the honest-floor path is unchanged. A floor at or below the running version IS what
# it claims, so the original refusal stands; and a running version the guard cannot read cannot
# judge the floor against it, so the original refusal stands there too.
assert_contains "floor at the running version, bundle below: the original migrated-forward refusal" "$(guard 1.17.0 1.17.0 1.10.0)" "migrated forward"
assert_contains "floor below the running version, bundle below the floor: the original refusal" "$(guard 2.1.0 2.0.0 1.10.0)" "migrated forward"
assert_contains "unreadable running version: the original refusal, not a judgement it cannot make" "$(guard dev 2.0.0 1.10.0)" "migrated forward"
assert_contains "a corrupt floor is still refused as unreadable, above or below" "$(guard 1.17.0 not-a-version 1.10.0)" "floor is unreadable"
unset -f guard
unset out hold_else commit_cleanup BOOT
rm -rf "$DF"
unset DF BD

# The other data-migration refusal: no room on the Tari data volume for the migration (#2645).
# shellcheck source=tests/stack/appliance/os-update-migration-space.sh
source "$HERE/appliance/os-update-migration-space.sh" || return $?
