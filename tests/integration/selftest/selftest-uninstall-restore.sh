#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-reset-restore.sh"
source "$HERE/../lib/run-uninstall-restore.sh"

for fault in none backup uninstall restore residue config secrets old-container census cleanup health; do
    (
        OUT_DIR=$(mktemp -d)
        trap 'rm -rf "$OUT_DIR"' EXIT
        IT_FAIL=0 IT_PASS=0 IT_PITHEAD=./pithead
        restored=no
        rx() {
            case "$1" in
            'source ./pithead'*) printf diy ;;
            *'ps --all --no-trunc'*)
                [ "$fault" != census ] || return 1
                if [ "$restored" = yes ] && [ "$fault" != old-container ]; then printf '%064d' 2; else printf '%064d' 1; fi
                ;;
            'sha256sum config.json')
                if [ "$fault" = config ] && [ "$restored" = yes ]; then printf changed; else printf original; fi
                ;;
            *' backup -y') [ "$fault" != backup ] ;;
            'umask 077; mktemp -d '*)
                mkdir -p "$OUT_DIR/private"
                printf '%s' "$OUT_DIR/private"
                ;;
            'umask 077; openssl rand '*) touch "$OUT_DIR/private/passphrase" ;;
            ls*) printf 'backups/pithead-backup-fixture.tar.gz.enc' ;;
            mv*) touch "$OUT_DIR/private/archive.enc" ;;
            'test ! -e .env') [ -e "$OUT_DIR/removed" ] ;;
            *' restore -y '*)
                [ "$fault" != restore ] || return 1
                touch "$OUT_DIR/restored"
                ;;
            rm*)
                [ "$fault" != cleanup ] || return 1
                rm -f "$OUT_DIR/private/passphrase" "$OUT_DIR/private/archive.enc"
                rmdir "$OUT_DIR/private"
                ;;

            *) return 127 ;;
            esac
        }
        upgrade_secret_fingerprints() {
            if [ "$fault" = secrets ] && [ -e "$OUT_DIR/restored" ]; then printf changed; else printf original; fi
        }
        pithead() {
            [ "$fault" != uninstall ] || return 1
            touch "$OUT_DIR/removed"
        }
        reset_restore_wait_empty() { [ "$fault" != residue ]; }
        wait_for() {
            if [ -e "$OUT_DIR/restored" ]; then restored=yes; fi
            shift 3
            "$@"
        }
        rr_web_ports_owned_by_dashboard() { :; }
        wait_status_ok() { [ "$fault" != health ]; }
        it_skip_leg() { :; }
        outcome=0
        run_uninstall_restore >"$OUT_DIR/output" 2>&1 || outcome=$?
        if [ "$fault" != cleanup ]; then
            [ ! -e "$OUT_DIR/private" ] || {
                printf 'FAIL: %s retained secret fixture\n' "$fault"
                exit 1
            }
        fi
        if [ "$fault" = none ]; then
            [ "$outcome:$IT_FAIL" = 0:0 ] || {
                cat "$OUT_DIR/output"
                exit 1
            }
        else
            [ "$outcome" -ne 0 ] || {
                printf 'FAIL: accepted %s\n' "$fault"
                exit 1
            }
        fi
    )
done
echo 'uninstall restore: PASS (success and independent failure controls)'
