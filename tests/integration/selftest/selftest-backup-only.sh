#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2030,SC2031,SC2329
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${BACKUP_ONLY_TEST_ROOT:-$HERE/..}"
source "$HERE/../lib.sh"
fixture="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$fixture"' EXIT

run_selection() {
    local name="$1" backup_rc="$2" health_rc="$3"
    shift 3
    (
        trap - EXIT
        eval "$(sed -n '/^IT_MODE=/,/^INTEGRATION_RUN_SUITE=1/p' "$ROOT/run.sh")"
        source "$ROOT/lib/run-cli.sh"
        source "$ROOT/lib/run-safety.sh"
        eval "$(sed -n '/^main() {$/,/^}$/p' "$ROOT/run.sh")"
        IT_PASS=0 IT_FAIL=0 IT_ALERT_REFUSED=0 IT_FAILED_NAMES="" _UPGRADE_RESTORE_ARMED=0
        OUT_DIR="$fixture/$name"
        mkdir -p "$OUT_DIR/source"
        printf '{}' >"$OUT_DIR/source/config.json"
        printf 'fixture=true\n' >"$OUT_DIR/source/.env"
        archive="$OUT_DIR/source/backups/pithead-backup-20260101-000000.tar.gz"
        if [ "$name" = symlinked-backups ]; then
            mkdir -p "$OUT_DIR/real-backups"
            ln -s "$OUT_DIR/real-backups" "$OUT_DIR/source/backups"
        elif [ "$name" = relative-path ]; then
            archive="$OUT_DIR/source/pithead-backup-20260101-000000.tar.gz"
        else
            mkdir -p "$OUT_DIR/source/backups"
        fi
        cd "$OUT_DIR/source" || exit 99
        : >"$OUT_DIR/victim"
        trace="$OUT_DIR/trace"
        : >"$trace"
        preflight() { printf 'preflight\n' >>"$trace"; }
        rig_lock() { printf 'lock\n' >>"$trace"; }
        validate_live_gate_args() { :; }
        rx() {
            case "$name:$1" in
            cleanup-failed:rm*) return 1 ;;
            interrupted-validation:'test -f'*) exit 143 ;;
            corrupt:tar*)
                printf 'config.json\n.env\n'
                return 2
                ;;
            pwd-failed:'pwd -P') return 1 ;;
            pwd-relative:'pwd -P')
                printf 'source\n'
                return 0
                ;;
            linked-stack:pwd)
                printf '%s/link\n' "$OUT_DIR"
                return 0
                ;;
            *:pwd | *:'pwd -P')
                printf '%s/source\n' "$OUT_DIR"
                return 0
                ;;
            *:'docker compose ps' | *' status')
                printf '%s\n' "$1" >>"$trace.rx"
                printf 'stub\n'
                return 0
                ;;
            esac
            eval "$1"
        }
        pithead() {
            printf '%s\n' "$*" >>"$trace"
            [ "$*" = 'backup -y --no-encrypt' ] || return 99
            if [ "$name" = wrong-root ]; then
                tar -czf "$archive" -C "$OUT_DIR" source/config.json source/.env
            elif [ "$name" = linked-stack ]; then
                ln -s "$OUT_DIR/source" "$OUT_DIR/link"
                tar -czf "$archive" -C / "${OUT_DIR#/}/link/config.json" "${OUT_DIR#/}/link/.env"
            elif [ "$name" = dot-prefix ]; then
                tar -czf "$archive" -C / "./${OUT_DIR#/}/source/config.json" "./${OUT_DIR#/}/source/.env"
            elif [ "$name" = misleading ]; then
                mv "$OUT_DIR/source/config.json" "$OUT_DIR/source/config.json.bad"
                mv "$OUT_DIR/source/.env" "$OUT_DIR/source/.env.bad"
                tar -czf "$archive" -C / "${OUT_DIR#/}/source/config.json.bad" "${OUT_DIR#/}/source/.env.bad"
            else
                tar -czf "$archive" -C / "${OUT_DIR#/}/source/config.json" "${OUT_DIR#/}/source/.env"
            fi
            case "$name" in
            relative-path) printf 'Backup written to: pithead-backup-20260101-000000.tar.gz\n' ;;
            traversal)
                mkdir -p "$OUT_DIR/source/backups/pithead-backup-x"
                cp "$archive" "$OUT_DIR/source/backups/victim.tar.gz"
                printf 'Backup written to: %s\n' "$OUT_DIR/source/backups/pithead-backup-x/../victim.tar.gz"
                ;;
            failed-nonregular)
                ln -s missing "$OUT_DIR/source/backups/pithead-backup-20260101-000001.tar.gz"
                printf 'Backup written to: %s\n' "$OUT_DIR/source/backups/pithead-backup-20260101-000001.tar.gz"
                ;;
            foreign-path)
                cp "$archive" "$OUT_DIR/victim"
                printf 'Backup written to: %s\n' "$OUT_DIR/victim"
                ;;
            foreign-dir)
                cp "$archive" "$OUT_DIR/pithead-backup-20260101-000000.tar.gz"
                printf 'Backup written to: %s\n' "$OUT_DIR/pithead-backup-20260101-000000.tar.gz"
                ;;
            *) printf 'Backup written to: %s\n' "$archive" ;;
            esac
            return "$backup_rc"
        }
        wait_status_ok() {
            printf 'health\n' >>"$trace"
            [ "$name" != interrupted ] || exit 143
            return "$health_rc"
        }
        safety_restore_exact() {
            printf 'recovery\n' >>"$trace"
            [ "$name" != interrupted-recovery ] || exit 143
            SAFETY_RESTORE_FAILED=1
            return 1
        }
        for fn in hugepages_begin hugepages_finish arm_safety_abort_restore run_scenario run_lifecycle \
            run_fault_injection run_auth_fail_closed restore_baseline safety_rollback_if_failed; do
            case "$name:$fn" in interrupted*:arm_safety_abort_restore | failed-nonregular:arm_safety_abort_restore) continue ;; esac
            eval "$fn() { printf '%s\n' '$fn' >>\"\$trace\"; }"
        done
        scenario_matrix() { printf 'fixture\t{}\n'; }
        if [ "$name" = interrupted-diagnostics ]; then
            mkdir() { exit 143; }
        fi
        main --local "$@"
    ) >"$fixture/$name.log" 2>&1
}

echo "== exclusive backup-only selection, archive validation and recovery =="
run_selection success 0 0 --backup-only
assert_rc "backup-only succeeds" "$?" 0
assert_eq "only reservation, preflight, backup and health run" \
    "$(cat "$fixture/success/trace")" $'lock\npreflight\narm_safety_abort_restore\nbackup -y --no-encrypt\nhealth'
assert_contains "archive members are validated" "$(cat "$fixture/success.log")" 'backup archive contains config.json'
assert_contains "env member is validated" "$(cat "$fixture/success.log")" 'backup archive contains .env'
assert_contains "completion identifies the focused selection" "$(cat "$fixture/success.log")" 'backup-only selection completed'
assert_eq "successful backup archive is cleaned" "$(if [ -e "$fixture/success/source/backups/pithead-backup-20260101-000000.tar.gz" ]; then echo present; else echo absent; fi)" absent

run_selection failed 7 0 --backup-only
assert_rc "backup failure fails the selection" "$?" 1
assert_eq "failed backup cannot reach scenarios or cleanup" \
    "$(cat "$fixture/failed/trace")" $'lock\npreflight\narm_safety_abort_restore\nbackup -y --no-encrypt'
assert_eq "failed restart retains the archive" "$(if [ -f "$fixture/failed/source/backups/pithead-backup-20260101-000000.tar.gz" ]; then echo present; else echo absent; fi)" present

run_selection failed-nonregular 7 0 --backup-only
assert_rc "a failed backup naming a non-regular path fails" "$?" 1
assert_eq "a failed backup never removes a non-regular reported path" "$(if [ -L "$fixture/failed-nonregular/source/backups/pithead-backup-20260101-000001.tar.gz" ]; then echo present; else echo absent; fi)" present

run_selection interrupted-recovery 0 1 --backup-only
assert_rc "an interrupted recovery fails the run" "$?" 1
assert_eq "an interrupted recovery keeps its restore archive" "$(if [ -f "$fixture/interrupted-recovery/source/backups/pithead-backup-20260101-000000.tar.gz" ]; then echo present; else echo absent; fi)" present

run_selection interrupted-diagnostics 0 1 --backup-only
assert_rc "an interrupt during recovery diagnostics fails the run" "$?" 1
assert_eq "an interrupt during recovery diagnostics keeps the archive" "$(if [ -f "$fixture/interrupted-diagnostics/source/backups/pithead-backup-20260101-000000.tar.gz" ]; then echo present; else echo absent; fi)" present

run_selection interrupted-validation 0 0 --backup-only
assert_rc "an interrupt during archive validation keeps its exit status" "$?" 143
assert_eq "an interrupt during archive validation removes nothing" "$(if [ -f "$fixture/interrupted-validation/source/backups/pithead-backup-20260101-000000.tar.gz" ]; then echo present; else echo absent; fi)" present

run_selection traversal 0 0 --backup-only
assert_rc "a traversing reported archive path fails" "$?" 1
assert_eq "a traversing reported archive path is never removed" "$(if [ -f "$fixture/traversal/source/backups/victim.tar.gz" ]; then echo present; else echo absent; fi)" present

run_selection relative-path 0 0 --backup-only
assert_rc "a relative reported archive path fails" "$?" 1
assert_eq "a relative reported archive path is never removed" "$(if [ -f "$fixture/relative-path/source/pithead-backup-20260101-000000.tar.gz" ]; then echo present; else echo absent; fi)" present

run_selection unhealthy 0 1 --backup-only
assert_rc "unhealthy post-backup stack fails" "$?" 1
assert_contains "existing recovery is preserved" "$(cat "$fixture/unhealthy/trace")" recovery
assert_eq "recovery diagnostics stay on the stubbed target" "$(cat "$fixture/unhealthy/trace.rx")" $'docker compose ps\n./pithead status'
assert_eq "failed recovery retains the archive" "$(if [ -f "$fixture/unhealthy/source/backups/pithead-backup-20260101-000000.tar.gz" ]; then echo present; else echo absent; fi)" present

run_selection symlinked-backups 0 0 --backup-only
assert_rc "a symlinked backups directory is accepted" "$?" 0
assert_eq "the archive behind a symlinked backups directory is cleaned" "$(if [ -e "$fixture/symlinked-backups/real-backups/pithead-backup-20260101-000000.tar.gz" ]; then echo present; else echo absent; fi)" absent

run_selection linked-stack 0 0 --backup-only
assert_rc "members written through a symlinked stack directory are accepted" "$?" 0

run_selection dot-prefix 0 0 --backup-only
assert_rc "dot-prefixed archive members are accepted" "$?" 0
assert_eq "dot-prefixed archive is cleaned" "$(if [ -e "$fixture/dot-prefix/source/backups/pithead-backup-20260101-000000.tar.gz" ]; then echo present; else echo absent; fi)" absent

for case in cleanup-failed:present corrupt:absent misleading:absent wrong-root:absent; do
    name="${case%%:*}"
    run_selection "$name" 0 0 --backup-only
    assert_rc "$name cannot pass backup-only" "$?" 1
    assert_eq "$name archive is ${case#*:}" "$(if [ -f "$fixture/$name/source/backups/pithead-backup-20260101-000000.tar.gz" ]; then echo present; else echo absent; fi)" "${case#*:}"
    assert_eq "$name cannot claim completion" "$(grep -c 'backup-only selection completed' "$fixture/$name.log")" 0
done

for name in foreign-path foreign-dir; do
    run_selection "$name" 0 0 --backup-only
    assert_rc "$name is not accepted as the safety archive" "$?" 1
    assert_eq "$name leaves the run's own archive in place" "$(grep -c 'nothing removed' "$fixture/$name.log")" 1
    assert_eq "$name is never removed" "$(if [ -f "$fixture/$name/victim" ] && [ -f "$fixture/$name/source/backups/pithead-backup-20260101-000000.tar.gz" ]; then echo present; else echo absent; fi)" present
done
assert_eq "an archive outside the stack backups directory is left alone" \
    "$(if [ -f "$fixture/foreign-dir/pithead-backup-20260101-000000.tar.gz" ]; then echo present; else echo absent; fi)" present

for name in pwd-failed pwd-relative; do
    run_selection "$name" 0 0 --backup-only
    assert_rc "$name stack root fails backup-only" "$?" 1
    assert_eq "$name stops before taking a backup" "$(cat "$fixture/$name/trace")" $'lock\npreflight\narm_safety_abort_restore'
done

run_selection interrupted 0 0 --backup-only
assert_rc "an interrupted backup-only run keeps its exit status" "$?" 143
assert_eq "an interrupt removes the archive without a restore" \
    "$(
        cat "$fixture/interrupted/trace"
        if [ -e "$fixture/interrupted/source/backups/pithead-backup-20260101-000000.tar.gz" ]; then echo present; else echo absent; fi
    )" \
    $'lock\npreflight\nbackup -y --no-encrypt\nhealth\nabsent'

for flag in --lifecycle --fault-injection --auth-fail-closed --hardening --rotate-onion --rigforge \
    --rigforge-control --subnet --rotate-secrets --xvb-routing-smoke --alert-egress \
    --mergemine-submit --tari-stranded --monero-stranded --mergemine-localnet --check --readiness --keep; do
    name="refused-${flag#--}"
    run_selection "$name" 0 0 --backup-only "$flag"
    assert_rc "backup-only refuses $flag" "$?" 2
    assert_eq "refusal precedes target access for $flag" "$(cat "$fixture/$name/trace")" ''
done
for rig in '--rig-name rig-a' '--rig-host 192.0.2.10'; do
    name="refused-${rig%% *}"
    # shellcheck disable=SC2086
    run_selection "$name" 0 0 --backup-only $rig
    assert_rc "backup-only refuses ${rig%% *}" "$?" 2
    assert_eq "rig refusal precedes target access for ${rig%% *}" "$(cat "$fixture/$name/trace")" ''
done
run_selection scenario 0 0 --backup-only --scenario local-pruned-main-secure-tari
assert_rc "backup-only refuses an explicit scenario" "$?" 2
assert_eq "scenario refusal precedes target access" "$(cat "$fixture/scenario/trace")" ''

run_selection modifier 0 0 --safety-backup
assert_rc "the original safety-backup modifier still works" "$?" 0
assert_contains "the modifier still runs scenarios" "$(cat "$fixture/modifier/trace")" run_scenario

source "$HERE/../lib/harness-args.sh"
validate_wrapper() {
    (
        MODE="$1" BORROW_MINER="$2" KEEP="$3" SCENARIO="$4"
        shift 4
        HARNESS_ARGS=("$@")
        die() { exit 2; }
        validate_harness_args || exit $?
        printf '%s|%s' "$HARNESS_PHASE_ARGS" "${TARGETED_SCENARIO_ARGS-unset}"
    )
}
assert_eq "targeted wrapper suppresses its scenario" "$(validate_wrapper targeted 0 0 '' --backup-only)" ' --backup-only|'
assert_eq "matrix wrapper selects backup-only" "$(validate_wrapper matrix 0 0 '' --backup-only)" ' --backup-only|'
for args in 'targeted 1 0' 'targeted 0 1' 'check 0 0'; do
    # shellcheck disable=SC2086
    validate_wrapper $args '' --backup-only >/dev/null
    assert_rc "wrapper refuses incompatible settings: $args" "$?" 2
done
validate_wrapper matrix 0 0 local-pruned-main-secure-tari --backup-only >/dev/null
assert_rc "wrapper refuses a scenario" "$?" 2
validate_wrapper targeted 0 0 '' --backup-only --lifecycle >/dev/null
assert_rc "wrapper refuses a lifecycle phase" "$?" 2
validate_wrapper targeted 0 0 '' --backup-only --scenario local-pruned-main-secure-tari >/dev/null
assert_rc "wrapper refuses a harness-arg scenario" "$?" 2
validate_wrapper targeted 0 0 '' --backup-only --sweep >/dev/null
assert_rc "wrapper refuses a sweep" "$?" 2

it_log "$IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
