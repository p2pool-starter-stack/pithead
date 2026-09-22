#!/usr/bin/env bash
# shellcheck disable=SC2034 # fixture globals are consumed by sourced functions and child shells
# The phase's hidden-service backup lies outside config.json/.env, so prove the real EXIT path
# calls it first on both an ordinary failure and a supervisor interruption.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
# shellcheck source=tests/integration/lib.sh
source "$ROOT/lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-hardening.sh
source "$ROOT/lib/run-hardening.sh"
# shellcheck source=tests/integration/lib/run-rotate-onion.sh
source "$ROOT/lib/run-rotate-onion.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

trial() {
    local cause="$1"
    local calls="$WORK/$cause"
    local rc
    if ROOT="$ROOT" CALLS="$calls" CAUSE="$cause" bash -c '
        set -uo pipefail
        source "$ROOT/lib.sh"
        INTEGRATION_RUN_SUITE=1
        source "$ROOT/lib/run-hardening.sh"
        source "$ROOT/lib/run-rotate-onion.sh"
        source "$ROOT/lib/run-safety.sh"
        rx() {
            case "$1" in
                *"docker compose up -d tor"*) printf "swap\n" >>"$CALLS" ;;
                *"/hostname"*) printf "hostname\n" >>"$CALLS"; printf "old.onion\n" ;;
                *"restart caddy"*) printf "caddy\n" >>"$CALLS" ;;
                *"rm -f"*) printf "cleanup\n" >>"$CALLS" ;;
            esac
        }
        rotate_onion_key_fingerprint() { printf "key\n" >>"$CALLS"; printf "keys\n"; }
        rotate_onion_env_fingerprint() { printf "envs\n"; }
        pithead() { printf "render\n" >>"$CALLS"; }
        wait_status_ok() { printf "health\n" >>"$CALLS"; }
        _onion_reachable_external() { printf "external\n" >>"$CALLS"; }
        SAFETY_BACKUP=0 RUN_ROTATE_ONION=1 SAFETY_ARCHIVE="" SAFETY_RESTORE_FAILED=0
        _SAFETY_RESTORE_ARMED=0 _SAFETY_FOREIGN_TRAP=""
        safety_backup
        ROTATE_ONION_HS_DIR=/fixture/dashboard
        ROTATE_ONION_BACKUP_DIR=/fixture/preserve
        ROTATE_ONION_ENV_BACKUP=/fixture/env
        ROTATE_ONION_OLD_ADDRESS=old.onion
        ROTATE_ONION_OLD_KEY_FP=keys
        ROTATE_ONION_OLD_ENV_FP=envs
        ROTATE_ONION_RESTORE_ARMED=1
        case "$CAUSE" in failure) exit 9 ;; interruption) kill -TERM $$; sleep 1 ;; esac
    ' >/dev/null 2>&1; then
        rc=0
    else
        rc=$?
    fi
    local expected
    expected="$(printf 'swap\nkey\nhostname\nrender\ncaddy\nhealth\nexternal\ncleanup')"
    [ "$rc" -ne 0 ] && [ "$(cat "$calls")" = "$expected" ]
}

trial failure && it_pass "a failed onion rotation restores its identity before the safety archive" ||
    it_fail "a failed onion rotation restores its identity before the safety archive"
trial interruption && it_pass "an interrupted onion rotation restores its identity before the safety archive" ||
    it_fail "an interrupted onion rotation restores its identity before the safety archive"

if (
    ROTATE_ONION_RESTORE_ARMED=1 ROTATE_ONION_HS_DIR=/fixture/dashboard
    ROTATE_ONION_BACKUP_DIR=/fixture/preserve ROTATE_ONION_ENV_BACKUP=/fixture/env
    ROTATE_ONION_OLD_ADDRESS=old.onion ROTATE_ONION_OLD_KEY_FP=keys ROTATE_ONION_OLD_ENV_FP=envs
    rx() { case "$1" in *"sudo cat"*) printf 'old.onion\n' ;; esac }
    rotate_onion_key_fingerprint() { printf 'keys\n'; }
    rotate_onion_env_fingerprint() { printf 'envs\n'; }
    pithead() { :; }
    wait_status_ok() { :; }
    _onion_reachable_external() { :; }
    rotate_onion_restore && [ "$ROTATE_ONION_RESTORE_ARMED" = 0 ]
); then
    it_pass "restore verifies the keys and hostname derived from the restored hidden-service identity"
else
    it_fail "restore verifies the keys and hostname derived from the restored hidden-service identity"
fi

if (
    ROTATE_ONION_RESTORE_ARMED=1 ROTATE_ONION_HS_DIR=/fixture/dashboard
    ROTATE_ONION_BACKUP_DIR=/fixture/preserve ROTATE_ONION_ENV_BACKUP=/fixture/env
    ROTATE_ONION_OLD_ADDRESS=old.onion ROTATE_ONION_OLD_KEY_FP=keys ROTATE_ONION_OLD_ENV_FP=envs
    rx() { case "$1" in *"sudo cat"*) printf 'old.onion\n' ;; esac }
    rotate_onion_key_fingerprint() { printf 'wrong-keys\n'; }
    rotate_onion_env_fingerprint() { printf 'envs\n'; }
    pithead() { :; }
    wait_status_ok() { :; }
    _onion_reachable_external() { :; }
    ! rotate_onion_restore && [ "$ROTATE_ONION_RESTORE_ARMED" = 1 ]
); then
    it_pass "restore rejects mismatched hidden-service key material without logging it"
else
    it_fail "restore rejects mismatched hidden-service key material without logging it"
fi

if (
    ROTATE_ONION_RESTORE_ARMED=1 ROTATE_ONION_HS_DIR=/fixture/dashboard
    ROTATE_ONION_BACKUP_DIR=/fixture/preserve ROTATE_ONION_ENV_BACKUP=/fixture/env
    ROTATE_ONION_OLD_ADDRESS=old.onion ROTATE_ONION_OLD_KEY_FP=keys ROTATE_ONION_OLD_ENV_FP=envs
    render_calls=0
    rx() { case "$1" in *"sudo cat"*) printf 'old.onion\n' ;; esac }
    rotate_onion_key_fingerprint() { printf 'keys\n'; }
    rotate_onion_env_fingerprint() { printf 'envs\n'; }
    pithead() {
        render_calls=$((render_calls + 1))
        [ "$render_calls" -gt 1 ]
    }
    wait_status_ok() { :; }
    _onion_reachable_external() { :; }
    ! rotate_onion_restore && [ "$ROTATE_ONION_RESTORE_ARMED" = 1 ] &&
        rotate_onion_restore && [ "$ROTATE_ONION_RESTORE_ARMED" = 0 ]
); then
    it_pass "a post-swap render failure stays armed and succeeds on EXIT retry"
else
    it_fail "a post-swap render failure stays armed and succeeds on EXIT retry"
fi

if (
    ROTATE_ONION_RESTORE_ARMED=1 ROTATE_ONION_HS_DIR=/fixture/dashboard
    ROTATE_ONION_BACKUP_DIR=/fixture/preserve ROTATE_ONION_ENV_BACKUP=/fixture/env
    ROTATE_ONION_OLD_ADDRESS=old.onion ROTATE_ONION_OLD_KEY_FP=keys ROTATE_ONION_OLD_ENV_FP=envs
    rx() {
        case "$1" in
        "test -e /fixture/env"*) return 1 ;;
        *"sudo cat"*) printf 'old.onion\n' ;;
        esac
    }
    rotate_onion_key_fingerprint() { printf 'keys\n'; }
    rotate_onion_env_fingerprint() {
        [ "$1" = /fixture/env ] && return 1
        printf 'envs\n'
    }
    pithead() { :; }
    wait_status_ok() { :; }
    _onion_reachable_external() { :; }
    rotate_onion_restore && [ "$ROTATE_ONION_RESTORE_ARMED" = 0 ]
); then
    it_pass "an interruption after snapshot cleanup verifies restored state and disarms"
else
    it_fail "an interruption after snapshot cleanup verifies restored state and disarms"
fi

if (
    rx() { printf '/srv/fixture-tor\n'; }
    [ "$(rotate_onion_data_dir /srv/fixture-tor)" = /srv/fixture-tor ] &&
        ! rotate_onion_data_dir relative/path && ! rotate_onion_data_dir / &&
        ! rotate_onion_data_dir /srv/fixture-tor/../fixture-tor
); then
    it_pass "TOR_DATA_DIR must be an existing canonical absolute non-root directory"
else
    it_fail "TOR_DATA_DIR must be an existing canonical absolute non-root directory"
fi

mkdir -p "$WORK/env-box"
printf '%s\n' \
    'DASHBOARD_ONION_ADDRESS=fixture.onion' \
    'DASHBOARD_ONION_CLIENT_PUBKEY=public-fixture' \
    'DASHBOARD_ONION_CLIENT_PRIVKEY=private-fixture' >"$WORK/env-box/snapshot"
chmod 600 "$WORK/env-box/snapshot"
if (
    # shellcheck disable=SC2034 # read by rx
    IT_MODE=local IT_REMOTE_DIR="$WORK/env-box"
    fp="$(rotate_onion_env_fingerprint snapshot 1)"
    chmod 644 "$WORK/env-box/snapshot"
    rotate_onion_env_fingerprint snapshot 1 >/dev/null 2>&1
    mode_rc=$?
    chmod 600 "$WORK/env-box/snapshot"
    printf 'UNEXPECTED=value\n' >>"$WORK/env-box/snapshot"
    rotate_onion_env_fingerprint snapshot 1 >/dev/null 2>&1
    content_rc=$?
    [ -n "$fp" ] && [ "$mode_rc" -ne 0 ] && [ "$content_rc" -ne 0 ]
); then
    it_pass "credential snapshots require exact fields, ownership and mode 0600"
else
    it_fail "credential snapshots require exact fields, ownership and mode 0600"
fi

mkdir -p "$WORK/fingerprint/dashboard" "$WORK/fingerprint/p2pool"
printf 'secret\n' >"$WORK/fingerprint/dashboard/hs_ed25519_secret_key"
printf 'public\n' >"$WORK/fingerprint/dashboard/hs_ed25519_public_key"
cp "$WORK/fingerprint/dashboard/hs_ed25519_secret_key" "$WORK/fingerprint/p2pool/"
cp "$WORK/fingerprint/dashboard/hs_ed25519_public_key" "$WORK/fingerprint/p2pool/"
cp "$WORK/env-box/snapshot" "$WORK/fingerprint/.env"
if (
    rx() {
        SNIPPET="$1" bash -c 'sudo() { [ "$1" = -n ] && shift; "$@"; }; eval "$SNIPPET"'
    }
    key_fp="$(rotate_onion_key_fingerprint "$WORK/fingerprint/dashboard")" &&
        client_fp="$(rotate_onion_client_key_fingerprint "$WORK/fingerprint/.env")" &&
        mining_fp="$(rotate_onion_mining_fingerprint "$WORK/fingerprint")" &&
        rm "$WORK/fingerprint/dashboard/hs_ed25519_secret_key" &&
        broken="$(rotate_onion_key_fingerprint "$WORK/fingerprint/dashboard" 2>/dev/null)"
    broken_rc=$?
    rm "$WORK/fingerprint/p2pool/hs_ed25519_secret_key"
    ln -s hs_ed25519_public_key "$WORK/fingerprint/p2pool/hs_ed25519_secret_key"
    mining_broken="$(rotate_onion_mining_fingerprint "$WORK/fingerprint" 2>/dev/null)"
    mining_broken_rc=$?
    [ -n "$key_fp" ] && [ -n "$client_fp" ] && [ -n "$mining_fp" ] &&
        [ "$broken_rc" -ne 0 ] && [ -z "$broken" ] &&
        [ "$mining_broken_rc" -ne 0 ] && [ -z "$mining_broken" ]
); then
    it_pass "fingerprints emit only after every protected input was read successfully"
else
    it_fail "fingerprints emit only after every protected input was read successfully"
fi

ONION="$(printf 'a%.0s' {1..56}).onion"
probe_result() {
    local wanted_rc="$1" output="$2" saved_env="${3:-}"
    (
        PROBE_RC="$wanted_rc" PROBE_OUT="$output"
        rx() {
            case "$1" in
            docker\ build*) return 0 ;;
            *)
                printf '%s\n' "$PROBE_OUT"
                return "$PROBE_RC"
                ;;
            esac
        }
        _onion_reachable_external "$ONION" "$saved_env"
    )
}
probe_result 0 "PROBE-OK: reachable" /fixture/env
reachable_rc=$?
probe_result 1 "PROBE-FAIL: fixture.onion -> HTTP 000"
retired_rc=$?
probe_result 2 "PROBE-FAIL: tor did not bootstrap"
bootstrap_rc=$?
probe_result 1 "PROBE-FAIL: fixture.onion -> HTTP 500"
malformed_rc=$?
if [ "$reachable_rc" = 0 ] && [ "$retired_rc" = 1 ] && [ "$bootstrap_rc" = 2 ] && [ "$malformed_rc" = 3 ]; then
    it_pass "external onion probe distinguishes retirement from infrastructure errors"
else
    it_fail "external onion probe distinguishes retirement from infrastructure errors"
fi

if (
    calls=0
    ROTATE_ONION_OLD_ENV_FP=envs
    rotate_onion_env_fingerprint() { printf 'envs\n'; }
    _onion_reachable_external() {
        calls=$((calls + 1))
        [ "$calls" -eq 1 ] && return 0
        return 1
    }
    sleep() { :; }
    wait_onion_retired "$ONION" /fixture/env && [ "$calls" = 2 ]
); then
    it_pass "retirement waits through a reachable transition and accepts only proven unreachability"
else
    it_fail "retirement waits through a reachable transition and accepts only proven unreachability"
fi

if (
    ROTATE_ONION_OLD_ENV_FP=envs
    rotate_onion_env_fingerprint() { printf 'envs\n'; }
    _onion_reachable_external() { return 2; }
    wait_onion_retired "$ONION" /fixture/env
    rc=$?
    [ "$rc" = 2 ]
); then
    it_pass "retirement refuses a Tor bootstrap failure"
else
    it_fail "retirement refuses a Tor bootstrap failure"
fi

state_line="$(grep -n 'ROTATE_ONION_OLD_KEY_FP="\$old_key_fp"' "$ROOT/lib/run-rotate-onion.sh" | cut -d: -f1)"
arm_line="$(grep -n '^[[:space:]]*ROTATE_ONION_RESTORE_ARMED=1$' "$ROOT/lib/run-rotate-onion.sh" | cut -d: -f1)"
rotate_line="$(grep -n 'pithead rotate-dashboard-onion -y' "$ROOT/lib/run-rotate-onion.sh" | cut -d: -f1)"
if [ "$state_line" -lt "$arm_line" ] && [ "$arm_line" -lt "$rotate_line" ]; then
    it_pass "restore state is complete before the trap arms and rotation begins"
else
    it_fail "restore state is complete before the trap arms and rotation begins"
fi

if ! grep -q 'it_skip_' "$ROOT/lib/run-rotate-onion.sh"; then
    it_pass "the explicitly selected rotate-onion phase fails instead of skipping missing fixture proof"
else
    it_fail "the explicitly selected rotate-onion phase fails instead of skipping missing fixture proof"
fi

backup_block="$(sed -n '/it_step "backing up the pre-rotation onion directory/,/ROTATE_ONION_HS_DIR=/p' "$ROOT/lib/run-rotate-onion.sh")"
if printf '%s\n' "$backup_block" | grep -q 'test -e' &&
    printf '%s\n' "$backup_block" | grep -q 'made_env=0 made_hs=0' &&
    printf '%s\n' "$backup_block" | grep -q 'cp -aT'; then
    it_pass "existing recovery copies are refused and a partial new backup is transactional"
else
    it_fail "existing recovery copies are refused and a partial new backup is transactional"
fi

if ! grep -q 'env_on_box DASHBOARD_ONION_CLIENT_PRIVKEY\|ROTATE_ONION_OLD_PRIVKEY' "$ROOT/lib/run-rotate-onion.sh"; then
    it_pass "client-auth private-key bytes stay on the box"
else
    it_fail "client-auth private-key bytes stay on the box"
fi

if (
    IT_MODE=local IT_ROTATE_ONION_FIXTURE_ATTESTATION="" failed=0
    it_log() { :; }
    it_fail() { failed=1; }
    run_rotate_onion
    rc=$?
    [ "$rc" = 1 ] && [ "$failed" = 1 ]
); then
    it_pass "rotation refuses an unattested target before reading its onion identity"
else
    it_fail "rotation refuses an unattested target before reading its onion identity"
fi

if (
    reads="$WORK/fixture-reads"
    IT_MODE=local IT_ROTATE_ONION_FIXTURE_ATTESTATION=/fixture/tor failed=0
    it_log() { :; }
    it_fail() { failed=1; }
    rotate_onion_data_dir() { printf '/fixture/tor\n'; }
    env_on_box() {
        printf '%s\n' "$1" >>"$reads"
        printf '/fixture/tor\n'
    }
    rx() { return 1; }
    run_rotate_onion
    rc=$?
    [ "$rc" = 1 ] && [ "$failed" = 1 ] && [ "$(cat "$reads")" = TOR_DATA_DIR ]
); then
    it_pass "rotation binds the actual Tor directory to a protected fixture marker before reading identity"
else
    it_fail "rotation binds the actual Tor directory to a protected fixture marker before reading identity"
fi

if grep -q 'docker compose ps --all -q' "$ROOT/lib/run-rotate-onion.sh" &&
    grep -q 'test -n "\$cids"' "$ROOT/lib/run-rotate-onion.sh" &&
    grep -q 'docker inspect.*|| exit 1' "$ROOT/lib/run-rotate-onion.sh"; then
    it_pass "credential backup mount exclusion requires every compose container inspection"
else
    it_fail "credential backup mount exclusion requires every compose container inspection"
fi

if grep -q 'env_backup="backups/rotate-onion-env-preserve"' "$ROOT/lib/run-rotate-onion.sh" &&
    grep -q 'umask 077' "$ROOT/lib/run-rotate-onion.sh"; then
    it_pass "the client credential snapshot stays owner-only outside Tor data"
else
    it_fail "the client credential snapshot stays owner-only outside Tor data"
fi

[ "$IT_FAIL" -eq 0 ] || exit 1
