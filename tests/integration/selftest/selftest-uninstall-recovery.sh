#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh" || exit $?
INTEGRATION_RUN_SUITE=1 source "$HERE/../lib/run-uninstall.sh" || exit $?
eval "$(sed -n '/^kept_data_snapshot_snippet() {/,/^}$/p' "$HERE/../lib/run-lifecycle.sh")"
eval "$(sed -n '/^safety_secret_drift_categories() {/,/^}$/p' "$HERE/../lib/run-safety.sh")"
eval "$(sed -n '/^safety_restore_exact() {/,/^}$/p' "$HERE/../lib/run-safety.sh")"
eval "$(sed -n '/^safety_abort_restore() {/,/^}$/p' "$HERE/../lib/run-safety.sh")"
eval "$(sed -n '/^safety_cleanup() {/,/^}$/p' "$HERE/../lib/run-safety.sh")"
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
    printf fixture >"$box/fixture"
    printf 'chain bytes\n' >"$box/monero/chain"
    # shellcheck disable=SC2034
    local IT_FAIL=0 IT_PASS=0 KEEP_STATE=0 KEPT_SNAPSHOT_SUDO="" IT_PITHEAD=./pithead RUN_UNINSTALL=1 OUT_DIR="$box"
    local BASELINE_CONFIG='{}' BASELINE_EXACT_SECRET_FP='proxy=fixture'
    local SAFETY_ARCHIVE=fixture SAFETY_RESTORE_FAILED=0 SAFETY_RESTORE_FAIL_REASON=""
    local _SAFETY_RESTORE_ARMED=1 _XVB_RESTORE_ARMED=1
    [ "$test_case" != keep ] || KEEP_STATE=1
    [ "$test_case" != missing-config ] || rm "$box/config.json"
    [ "$test_case" != diagnostic-blocked ] || mkdir "$box/uninstall-restore.log"
    if [ "$test_case" = diagnostic-stale ]; then
        printf stale >"$box/uninstall-restore.log"
        chmod 644 "$box/uninstall-restore.log"
    fi
    if [ "$test_case" = diagnostic-symlink ]; then
        printf untouched >"$box/other-output"
        ln -s "$box/other-output" "$box/uninstall-restore.log"
    fi
    it_log() { :; }
    it_step() { :; }
    it_warn() { :; }
    case "$test_case" in
    redact-fails | unit-redact-fails) redact() {
        printf 'partial diagnostic\n'
        return 1
    } ;;
    esac
    _lan_timer_pause() { return 0; }
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
            if [ "$test_case" = restore-fails ]; then
                printf 'PROXY_AUTH_TOKEN=changeme\nrestore destination refused\n' >&2
                return 1
            fi
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
        *'systemctl is-active pithead-lan.timer'*) return 0 ;;
        'docker compose ps -aq') printf 'container-id\n' ;;
        'rm -f .env.itest-round-trip'*)
            [ "$test_case" != cleanup-fails ] || return 1
            (cd "$box" && bash -c "$1")
            ;;
        *'docker image ls'*) cat "$box/resources" ;;
        *"printf 'nope"*)
            [ "$test_case" != abort-file ] || printf changed >>"$box/config.json"
            [ "$test_case" != abort-checkout ] || printf changed >>"$box/Caddyfile"
            [ "$test_case" != abort-resource ] || printf changed >>"$box/resources"
            [ "$test_case" != abort-kept ] || printf changed >>"$box/monero/chain"
            printf 'Aborted\n'
            return 1
            ;;
        'docker container ls -aq --no-trunc')
            [ "$(cat "$box/resources")" != installed ] || printf 'container-id\n'
            ;;
        *'systemctl list-unit-files'*)
            [ "$test_case" != systemd-fails ] || return 1
            case "$test_case" in
            units-remain | unit-redact-fails)
                [ "$(cat "$box/resources")" = installed ] || printf 'pithead-lan-hold.service not-found active exited fixture\n'
                ;;
            esac
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
    if [ "$test_case" = cleanup-fails ]; then
        safety_cleanup
        [ -f "$box/fixture" ] || it_fail 'cleanup failure retains the safety archive' 'the archive was deleted' >>"$box/run.log"
    fi
    if [ "$test_case" = keep ] && [ "$(cat "$box/resources")" != rebuilt ]; then
        it_fail '--keep retains the successful setup state' 'the exact baseline replaced the rebuilt state' >>"$box/run.log"
    fi
    printf '%s|%s|%s|%s' "$result" "$IT_FAIL" \
        "$(grep -c '^restore$' "$box/commands")" "$(grep -c '^roundtrip$' "$box/commands")"
)

echo "== uninstall preservation and phase-owned recovery =="
assert_eq 'the live-removal fault recovers exactly before a successful second round trip' "$(drive clean)" '0|0|1|2'
assert_eq '--keep still proves injected recovery and leaves the successful rebuilt state' "$(drive keep)" '0|0|1|2'
assert_eq 'a missing config snapshot refuses uninstall and restores before returning' "$(drive missing-config)" '1|1|1|0'
assert_eq 'abort-time file mutation fails the comparison and recovers before returning' "$(drive abort-file)" '1|1|1|0'
assert_eq 'abort-time host mutation fails the comparison and recovers before returning' "$(drive abort-resource)" '1|1|1|0'
assert_eq 'abort-time kept-data mutation fails and recovers before returning' "$(drive abort-kept)" '1|1|1|0'
assert_eq 'abort-time generated-file mutation fails and recovers before returning' "$(drive abort-checkout)" '1|1|1|0'
assert_contains 'file drift identifies the checkout component' "$(cat "$T/abort-checkout/run.log")" 'changed: checkout files;'
assert_contains 'resource drift identifies the host component' "$(cat "$T/abort-resource/run.log")" 'changed: host resources;'
assert_contains 'kept-data drift retains per-file evidence' "$(cat "$T/abort-kept/run.log")" 'monero/chain'
assert_eq 'a failed archive restore cannot pass because up becomes healthy' "$(drive restore-fails)" '1|1|1|1'
assert_contains 'failed restore retains its command diagnostic' "$(cat "$T/restore-fails/uninstall-restore.log")" 'restore destination refused'
assert_contains 'retained restore output redacts credentials' "$(cat "$T/restore-fails/uninstall-restore.log")" 'PROXY_AUTH_TOKEN=<redacted>'
assert_eq 'retained restore output never includes the credential value' "$(grep -c changeme "$T/restore-fails/uninstall-restore.log")" '0'
assert_eq 'retained restore output is owner-only' "$(stat -c '%a' "$T/restore-fails/uninstall-restore.log")" '600'
assert_eq 'failed diagnostic redaction does not change exact recovery' "$(drive redact-fails)" '0|0|1|2'
assert_eq 'failed redaction discards its partial restore diagnostic' "$([ -e "$T/redact-fails/uninstall-restore.log" ] && echo present || echo absent)" 'absent'
assert_eq 'an unwritable diagnostic destination cannot prevent exact recovery' "$(drive diagnostic-blocked)" '0|0|1|2'
assert_eq 'a stale diagnostic destination does not change exact recovery' "$(drive diagnostic-stale)" '0|0|1|2'
assert_eq 'a replaced diagnostic is owner-only even when the old file was not' "$(stat -c '%a' "$T/diagnostic-stale/uninstall-restore.log")" '600'
assert_eq 'a symlinked diagnostic destination does not change exact recovery' "$(drive diagnostic-symlink)" '0|0|1|2'
assert_eq 'a diagnostic destination symlink is replaced rather than followed' "$(cat "$T/diagnostic-symlink/other-output")" 'untouched'
assert_eq 'no private diagnostic temporaries remain' "$(find "$T" -name '.uninstall-diagnostic.*' | wc -l | tr -d ' ')" '0'
assert_eq 'remaining unit records still fail cleanup and recovery injection' "$(drive units-remain)" '1|2|1|1'
assert_contains 'remaining unit identities are retained for diagnosis' "$(cat "$T/units-remain/uninstall-systemd-units.log")" 'pithead-lan-hold.service not-found active exited'
assert_contains 'remaining unit identities appear in the bounded harness output' "$(cat "$T/units-remain/run.log")" 'pithead-lan-hold.service not-found active exited'
assert_eq 'failed unit-diagnostic redaction leaves cleanup binding and recovery intact' "$(drive unit-redact-fails)" '1|2|1|1'
assert_eq 'failed redaction discards its partial unit diagnostic' "$([ -e "$T/unit-redact-fails/uninstall-systemd-units.log" ] && echo present || echo absent)" 'absent'
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
