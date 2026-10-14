#!/usr/bin/env bash
# shellcheck disable=SC2034 # globals are consumed by sourced functions
# Drive the real rotate-onion backup path without Docker or a bench.
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
BOX="$WORK/e2e" TOR="$BOX/tor"
mkdir -p "$TOR/dashboard"
printf '%s\n' secret >"$TOR/dashboard/hs_ed25519_secret_key"
printf '%s\n' public >"$TOR/dashboard/hs_ed25519_public_key"
printf '%s\n' old.onion >"$TOR/dashboard/hostname"
printf '%s\n' "$TOR" >"$TOR.attestation"
chmod 600 "$TOR.attestation"
printf '%s\n' \
    'DASHBOARD_ONION_ADDRESS=old.onion' \
    'DASHBOARD_ONION_CLIENT_PUBKEY=old-public' \
    'DASHBOARD_ONION_CLIENT_PRIVKEY=old-private' >"$BOX/.env"

drive_backup() { # <reported-container-mount> -> run_rotate_onion rc
    (
        cd "$BOX" || exit 1
        IT_MODE=local IT_ROTATE_ONION_FIXTURE_ATTESTATION="$TOR"
        MOUNT_SOURCE="$1"
        it_log() { :; }
        it_step() { :; }
        it_fail() { :; }
        rotate_onion_data_dir() { printf '%s\n' "$TOR"; }
        env_on_box() {
            case "$1" in
            TOR_DATA_DIR) printf '%s\n' "$TOR" ;;
            DASHBOARD_ONION_ENABLED | DASHBOARD_ONION_CLIENT_AUTH) printf 'true\n' ;;
            DASHBOARD_ONION_ADDRESS) printf 'old.onion\n' ;;
            esac
        }
        _onion_reachable_external() { :; }
        rotate_onion_key_fingerprint() { printf 'key-fingerprint\n'; }
        rotate_onion_client_key_fingerprint() { printf 'client-fingerprint\n'; }
        rotate_onion_env_fingerprint() { printf 'env-fingerprint\n'; }
        rotate_onion_mining_fingerprint() { printf 'mining-fingerprint\n'; }
        rx() {
            BOX="$BOX" MOUNT_SOURCE="$MOUNT_SOURCE" SNIPPET="$1" bash -c '
                readlink() { [ "$1" = -f ] && shift; (cd "$1" && pwd -P); }
                stat() {
                    case "$1:$2" in
                    -c:%u) printf "0\n" ;;
                    -c:%a) command stat -f %Lp "$3" ;;
                    *) command stat "$@" ;;
                    esac
                }
                cp() { [ "$1" != -aT ] || shift; command cp -a "$@"; }
                sudo() { [ "$1" = -n ] || return 97; shift; "$@"; }
                docker() {
                    case "$1" in
                    ps) printf "fixture-container\n" ;;
                    inspect) printf "%s\n" "$MOUNT_SOURCE" ;;
                    esac
                }
                eval "$SNIPPET"
            '
        }
        pithead() { exit 23; }
        run_rotate_onion
    ) >/dev/null 2>&1
}

mkdir -p "$BOX/backups/child"
CHILD_MOUNT="$(cd "$BOX/backups/child" && pwd -P)"
drive_backup "$CHILD_MOUNT"
child_rc=$?
if [ "$child_rc" = 1 ] && [ ! -e "$BOX/backups/rotate-onion-identity-preserve" ] &&
    [ ! -e "$BOX/backups/rotate-onion-env-preserve" ]; then
    it_pass "a container mount below the host backup directory refuses every recovery copy"
else
    it_fail "a container mount below the host backup directory refuses every recovery copy" "rc=$child_rc"
fi
rmdir "$BOX/backups/child"

drive_backup "$WORK/unrelated-mount"
backup_rc=$?
identity="$BOX/backups/rotate-onion-identity-preserve"
if [ "$backup_rc" = 23 ] && [ -d "$identity" ] && [ -f "$identity/hs_ed25519_secret_key" ] &&
    [ ! -e "$TOR/dashboard.itest-preserve" ] &&
    [ "$(stat -c %a "$BOX/backups" 2>/dev/null || stat -f %Lp "$BOX/backups")" = 700 ] &&
    [ -f "$BOX/backups/rotate-onion-env-preserve" ]; then
    it_pass "rotation keeps both recovery copies in an owner-only host directory outside Tor data"
else
    it_fail "rotation keeps both recovery copies in an owner-only host directory outside Tor data" "rc=$backup_rc"
fi

[ "$IT_FAIL" -eq 0 ] || exit 1
