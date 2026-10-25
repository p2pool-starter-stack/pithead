#!/usr/bin/env bash
# shellcheck disable=SC2034
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/../lib/restore-proof.sh"
E2E_SRC="$HERE/../e2e.sh"
scratch=$(mktemp -d -t unit-capture.XXXXXX) || exit 1
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"
cat >"$scratch/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
printf '%s\n' 'private-stderr-sentinel' >&2
if [ "$1" = cat ]; then
    [ "${CAPTURE_FAIL_UNIT:-}" != "$2" ] || exit 1
    [ "${CAT_RESULT:-0}" = 0 ] || exit "$CAT_RESULT"
    printf '%s\n' 'private-unit-body-sentinel'
    exit 0
fi
[ "${SHOW_SLOW:-0}" = 0 ] || sleep 10
printf '%s' "${LOAD_STATE-loaded}"
exit "${SHOW_RESULT:-0}"
STUB
chmod +x "$scratch/bin/systemctl"
CALLS="$scratch/calls"
export CALLS
on_bench() { PATH="$scratch/bin:$PATH" bash -c "$1"; }

read_case() {
    egress_boot_unit_state "${1:-pithead-lan-guard.service}" >"$scratch/state" 2>"$scratch/diagnostic"
}
echo "== bounded unit reads and diagnostic classification =="
read_case
assert_eq "readable unit is present" "$(cat "$scratch/state")" present
assert_contains "successful capture retains a fixed diagnostic" "$(cat "$scratch/diagnostic")" 'state=present reason=verified'
CAT_RESULT=1 LOAD_STATE=not-found read_case
assert_eq "explicit not-found is absent" "$(cat "$scratch/state")" absent
for load in loaded masked error bad-setting stub merged; do
    CAT_RESULT=1 LOAD_STATE="$load" read_case
    assert_eq "$load after cat failure remains unknown" "$(cat "$scratch/state")" ''
    assert_contains "$load failure is classified" "$(cat "$scratch/diagnostic")" "reason=cat-failed-$load"
done
CAT_RESULT=1 SHOW_RESULT=1 LOAD_STATE=not-found read_case
assert_eq "a failed show cannot establish absence" "$(cat "$scratch/state")" ''
assert_contains "show failure has its own reason" "$(cat "$scratch/diagnostic")" 'reason=show-failed'
CAT_RESULT=1 LOAD_STATE='' read_case
assert_contains "empty load state is distinct" "$(cat "$scratch/diagnostic")" 'reason=load-state-empty'
CAT_RESULT=1 LOAD_STATE='private-output-sentinel' read_case
assert_contains "unsupported load state is classified without its value" "$(cat "$scratch/diagnostic")" 'reason=load-state-other'
assert_eq "unit bodies and stderr never enter diagnostics" "$(grep -c private "$scratch/diagnostic")" 0
assert_num_ge "all requested reads use the actual unit name" "$(grep -c pithead-lan-guard.service "$CALLS")" 10
CAT_RESULT=1 SHOW_SLOW=1 read_case
assert_contains "a timed-out show remains unknown" "$(cat "$scratch/diagnostic")" 'reason=show-failed'
(
    on_bench() {
        printf '%s\n' private-transport-sentinel >&2
        return 255
    }
    read_case
)
assert_eq "transport failure remains unknown" "$(cat "$scratch/state")" ''
assert_contains "transport failure is distinct" "$(cat "$scratch/diagnostic")" 'reason=transport-failed transport_exit=255'
assert_eq "transport stderr stays private" "$(grep -c private "$scratch/diagnostic")" 0
(
    on_bench() { printf '%s\n' private-protocol-sentinel; }
    read_case
)
assert_eq "unexpected probe output stays unknown" "$(cat "$scratch/state")" ''
assert_contains "missing protocol is distinct" "$(cat "$scratch/diagnostic")" 'reason=probe-output-unavailable'
: >"$CALLS"
read_case 'pithead-lan-guard.service;private-sentinel'
assert_eq "invalid unit sends no command" "$(cat "$CALLS")" ''
assert_eq "invalid unit is not reflected" "$(grep -c private "$scratch/diagnostic")" 0

echo "== parent-shell capture and restoration boundary =="
capture_restore_unit_states >"$scratch/capture" 2>"$scratch/diagnostic"
assert_rc "all required states capture successfully" "$?" 0
assert_eq "both LAN records survive command substitution" "$LAN_UNIT_BEFORE/$HOLD_UNIT_BEFORE" present/present
assert_eq "all five units have a capture row" "$(wc -l <"$scratch/capture" | tr -d ' ')" 5
verify_restore_unit_capture >"$scratch/restore"
assert_rc "unchanged parent-shell records verify" "$?" 0
LAN_UNIT_BEFORE=''
verify_restore_unit_capture >"$scratch/restore"
assert_rc "lost state fails restoration" "$?" 1
assert_contains "lost state differs from a failed capture" "$(cat "$scratch/restore")" 'unit=pithead-lan-guard.service state=unknown reason=state-changed-after-capture'
LAN_UNIT_BEFORE=absent
verify_restore_unit_capture >"$scratch/restore"
assert_rc "a changed valid state also fails" "$?" 1
RESTORE_UNIT_CAPTURE=''
verify_restore_unit_capture >"$scratch/restore"
assert_rc "missing capture evidence fails" "$?" 1
assert_contains "missing capture evidence is explicit" "$(cat "$scratch/restore")" 'reason=capture-unavailable'
CAPTURE_FAIL_UNIT=pithead-lan-hold.service capture_restore_unit_states >"$scratch/capture" 2>"$scratch/diagnostic"
assert_rc "one failed unit fails capture" "$?" 1
assert_eq "failed capture retains each unit independently" "$LAN_UNIT_BEFORE/$HOLD_UNIT_BEFORE" present/
verify_restore_unit_capture >"$scratch/restore"
assert_rc "a captured unknown cannot pass restoration" "$?" 1
assert_contains "the original read failure is retained" "$(cat "$scratch/diagnostic")" 'unit=pithead-lan-hold.service state=unknown reason=cat-failed-loaded'

(
    RESTORE_UNIT_CAPTURE=''
    RESTORE_DIR=/fixture E2E_DIR=/candidate BASELINE_IMAGES=fixture
    on_bench() {
        printf '%s\n' probe >>"$scratch/proof-actions"
        case "$1" in *'bash -s'*) echo rpc-ok ;; esac
    }
    env_bake_verdict() { echo match; }
    control_units_verdict() { echo on-target; }
    stack_restore_census() { echo fixture; }
    declared_image_census() { echo fixture; }
    grade_restore_identity() { echo 'verified fixture'; }
    chain_restore_proof() { :; }
    verify_chain_sync_proof() { :; }
    restore_egress_boot_unit() { echo removal >>"$scratch/proof-actions"; }
    restore_egress_check_units() { echo removal >>"$scratch/proof-actions"; }
    restore_lan_check_units() { echo removal >>"$scratch/proof-actions"; }
    restore_lan_unit() { echo removal >>"$scratch/proof-actions"; }
    ok() { :; }
    warn() { :; }
    : >"$scratch/proof-actions"
    verify_restore_proof
) >"$scratch/full-proof" 2>&1
assert_rc "the full restore proof rejects missing capture" "$?" 1
assert_eq "the full proof refuses before any probe or unit removal" "$(cat "$scratch/proof-actions")" ''

echo "== deploying refusal and read-only assessment =="
preflight_case() {
    (
        MODE="$1" KEEP=0 RESTORED=0 BORROW_MINER=0 BENCH_HOST=fixture MINER_HOST=''
        CANONICAL_DIR=/fixture E2E_DIR=/candidate RESTORE_DIR=/fixture
        BRANCH=fixture MINER_CFG_BACKUP='' SKIP_PREFLIGHT=1
        C_RED='' C_RESET=''
        export CAPTURE_FAIL_UNIT=pithead-lan-hold.service
        log() { :; }
        ok() { :; }
        warn() { :; }
        step() { :; }
        parent_lock_checkpoint() { :; }
        harness_clear_check_evidence() { :; }
        stack_image_census() { echo fixture; }
        on_bench() {
            printf '%s\n' "$1" >>"$scratch/commands"
            case "$1" in
            *'systemctl cat '*) PATH="$scratch/bin:$PATH" bash -c "$1" ;;
            esac
        }
        provision() { echo provision >>"$scratch/mutations"; }
        backup_stack() { echo backup >>"$scratch/mutations"; }
        wallet_fixture_capture() { echo wallet >>"$scratch/mutations"; }
        borrow_miner() { echo borrow >>"$scratch/mutations"; }
        deploy_branch() { echo deploy >>"$scratch/mutations"; }
        run_harness() { echo harness >>"$scratch/mutations"; }
        eval "$(sed -n '/^die() {$/,/^}$/p' "$E2E_SRC")"
        eval "$(sed -n '/^restore_all() {$/,/^}$/p' "$E2E_SRC")"
        eval "$(sed -n '/^preflight() {$/,/^}$/p' "$E2E_SRC")"
        eval "$(sed -n '/^main() {$/,/^}$/p' "$E2E_SRC")"
        trap restore_all EXIT
        main
    ) >"$scratch/preflight" 2>&1
}
: >"$scratch/mutations"
preflight_case targeted
assert_rc "deploying wrapper refuses incomplete capture" "$?" 1
assert_eq "refusal runs no provisioning, backup, wallet capture, borrow or deploy" "$(cat "$scratch/mutations")" ''
assert_eq "the EXIT trap sends no restore mutation" "$(grep -c 'sudo\|upgrade\|apply' "$scratch/commands")" 0
assert_contains "preflight refusal says why" "$(cat "$scratch/preflight")" 'refusing before backup, wallet capture or deployment'
preflight_case check
assert_rc "read-only check keeps its prior behavior" "$?" 0
assert_eq "read-only mode runs only checkout and assessment" "$(cat "$scratch/mutations")" $'provision\nharness'

printf 'restore-unit-capture self-test: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
