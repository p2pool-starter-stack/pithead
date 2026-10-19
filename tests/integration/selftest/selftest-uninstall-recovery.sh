#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh" || exit $?
INTEGRATION_RUN_SUITE=1 source "$HERE/../lib/run-uninstall.sh" || exit $?
eval "$(sed -n '/^kept_data_snapshot_snippet() {/,/^}$/p' "$HERE/../lib/run-lifecycle.sh")"
eval "$(sed -n '/^safety_secret_drift_categories() {/,/^}$/p' "$HERE/../lib/run-safety.sh")"
eval "$(sed -n '/^safety_restore_exact() {/,/^}$/p' "$HERE/../lib/run-safety.sh")"
eval "$(sed -n '/^safety_abort_restore() {/,/^}$/p' "$HERE/../lib/run-safety.sh")"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# shellcheck disable=SC2034,SC2154
drive() (
    local test_case="$1" box="$T/$1" result
    mkdir -p "$box"/{monero,tari,p2pool,dashboard,tor,backups}
    printf '{}' >"$box/config.json"
    printf 'fixture token\n' >"$box/.env"
    printf 'fixture proxy\n' >"$box/Caddyfile"
    printf 'installed\n' >"$box/resources"
    cp "$box/.env" "$box/env-baseline"
    printf 'chain bytes\n' >"$box/monero/chain"
    # shellcheck disable=SC2034
    local IT_FAIL=0 IT_PASS=0 KEEP_STATE=0 KEPT_SNAPSHOT_SUDO="" IT_PITHEAD=./pithead
    local BASELINE_CONFIG='{}' BASELINE_EXACT_SECRET_FP='proxy=fixture'
    local SAFETY_ARCHIVE=fixture SAFETY_RESTORE_FAILED=0 SAFETY_RESTORE_FAIL_REASON=""
    local _SAFETY_RESTORE_ARMED=1 _XVB_RESTORE_ARMED=1
    [ "$test_case" != keep ] || KEEP_STATE=1
    [ "$test_case" != missing-config ] || rm "$box/config.json"
    it_log() { :; }
    it_step() { :; }
    it_warn() { :; }
    _uninstall_data_dirs() { printf '%s\n' "$box/monero" "$box/tari" "$box/p2pool" "$box/dashboard" "$box/tor"; }
    wait_status_ok() { [ "$test_case" != health-fails ]; }
    upgrade_secret_fingerprints() {
        [ "$test_case" != unreadable-secrets ] || return 1
        if [ "$test_case" = changed-secrets ]; then printf 'proxy=changed'; else printf 'proxy=fixture'; fi
    }
    pithead() {
        printf '%s\n' "$1" >>"$box/commands"
        case "$1" in
        restore)
            [ "$test_case" != restore-fails ] || return 1
            printf '{}' >"$box/config.json"
            cp "$box/env-baseline" "$box/.env"
            printf 'fixture proxy\n' >"$box/Caddyfile"
            printf 'chain bytes\n' >"$box/monero/chain"
            printf 'installed\n' >"$box/resources"
            ;;
        up) [ "$test_case" != up-fails ] || return 1 ;;
        esac
    }
    baseline_up() { pithead up; }
    rx() {
        case "$1" in
        'docker compose stop') return 0 ;;
        'docker compose ps -aq') printf 'container-id\n' ;;
        'rm -f .env.itest-round-trip'*)
            [ "$test_case" != cleanup-fails ] || return 1
            (cd "$box" && bash -c "$1")
            ;;
        *'docker image ls'*) cat "$box/resources" ;;
        *"printf 'nope"*)
            [ "$test_case" != abort-file ] || printf changed >>"$box/config.json"
            [ "$test_case" != abort-resource ] || printf changed >>"$box/resources"
            printf 'Aborted\n'
            return 1
            ;;
        'docker container ls -aq --no-trunc')
            [ "$(cat "$box/resources")" != installed ] || printf 'container-id\n'
            ;;
        *'systemctl list-unit-files'*)
            [ "$test_case" != systemd-fails ] || return 1
            [ "$(cat "$box/resources")" != installed ] || printf 'pithead-control.service\n'
            ;;
        *'iptables-save'*) return 0 ;;
        *) (cd "$box" && bash -o pipefail -c "$1") ;;
        esac
    }
    run_uninstall_round_trip() {
        printf 'roundtrip\n' >>"$box/commands"
        printf 'removed\n' >"$box/resources"
        rm -f "$box/.env" "$box/Caddyfile"
        cp "$box/env-baseline" "$box/.env.itest-round-trip"
        [ "$test_case" != kept-write ] || printf changed >>"$box/monero/chain"
        _uninstall_after_remove "Kept: config.json $data_dirs" || return $?
        if [ "$test_case" = setup-fails ]; then
            it_fail 'setup after uninstall succeeded' 'injected setup failure'
            return 1
        fi
        cp "$box/env-baseline" "$box/.env"
        printf 'fixture proxy\n' >"$box/Caddyfile"
        printf 'rebuilt\n' >"$box/resources"
        rm -f "$box/.env.itest-round-trip"
    }
    run_uninstall_phase >"$box/run.log" 2>&1
    result=$?
    if [ -e "$box/.env.itest-round-trip" ]; then
        it_fail 'phase recovery removes its temporary secret copy' 'the duplicate .env remains' >>"$box/run.log"
    fi
    if [ "$test_case" = keep ] && [ "$(cat "$box/resources")" != rebuilt ]; then
        it_fail '--keep retains the successful setup state' 'the exact baseline replaced the rebuilt state' >>"$box/run.log"
    fi
    printf '%s|%s|%s|%s' "$result" "$IT_FAIL" \
        "$(grep -c '^restore$' "$box/commands")" "$(grep -c '^roundtrip$' "$box/commands")"
)

assert_eq 'the live-removal fault recovers exactly before a successful second round trip' "$(drive clean)" '0|0|1|2'
assert_eq '--keep still proves injected recovery and leaves the successful rebuilt state' "$(drive keep)" '0|0|1|2'
assert_eq 'a missing config snapshot refuses uninstall and restores before returning' "$(drive missing-config)" '1|1|1|0'
assert_eq 'abort-time file mutation fails the comparison and recovers before returning' "$(drive abort-file)" '1|1|1|0'
assert_eq 'abort-time host mutation fails the comparison and recovers before returning' "$(drive abort-resource)" '1|1|1|0'
assert_eq 'a failed archive restore cannot pass because up becomes healthy' "$(drive restore-fails)" '1|1|1|1'
assert_eq 'a failed startup stops the phase before the success trial' "$(drive up-fails)" '1|1|1|1'
assert_eq 'a failed health wait stops the phase before the success trial' "$(drive health-fails)" '1|1|1|1'
assert_eq 'unreadable restored secrets fail phase recovery' "$(drive unreadable-secrets)" '1|1|1|1'
assert_eq 'changed restored secrets fail phase recovery' "$(drive changed-secrets)" '1|1|1|1'
assert_eq 'a write in any configured kept path fails the phase and recovers' "$(drive kept-write)" '1|2|1|1'
assert_eq 'systemd inspection failure cannot look like successful cleanup' "$(drive systemd-fails)" '1|2|1|1'
assert_eq 'failure in the positive setup trial invokes phase-owned exact recovery' "$(drive setup-fails)" '1|1|2|2'
assert_eq 'temporary secret-copy cleanup failure prevents recovery from passing' "$(drive cleanup-fails)" '1|2|1|1'

interrupted_copy="$T/interrupted.env"
printf fixture >"$interrupted_copy"
(
    # shellcheck disable=SC2034
    RUN_UNINSTALL=1 _SAFETY_RESTORE_ARMED=0 _SAFETY_FOREIGN_TRAP=""
    rx() { rm -f "$interrupted_copy"; }
    trap safety_abort_restore EXIT
    exit 17
)
assert_rc 'the interrupted phase preserves its original error after cleanup' "$?" '17'
assert_eq 'the interruption trap deletes the temporary secret copy' "$([ -e "$interrupted_copy" ] && echo yes || echo no)" 'no'
(
    # shellcheck disable=SC2034
    RUN_UNINSTALL=1 _SAFETY_RESTORE_ARMED=0 _SAFETY_FOREIGN_TRAP=""
    rx() { return 1; }
    trap safety_abort_restore EXIT
    exit 17
)
assert_rc 'an interruption cleanup failure cannot return a successful verdict' "$?" '1'

echo "selftest-uninstall-recovery: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
