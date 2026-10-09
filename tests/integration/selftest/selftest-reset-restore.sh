#!/usr/bin/env bash
# Failure controls for the real encrypted config-reset recovery leg; no engine is started here.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
# shellcheck disable=SC2034 # consumed by the sourced leg
INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-reset-restore.sh"
echo "== encrypted config-reset recovery failure controls =="

drive_reset_restore() (
    local fault="$1"
    # shellcheck disable=SC2034 # consumed by the sourced leg
    IT_FAIL=0 IT_PASS=0 IT_PITHEAD=./pithead
    OUT_DIR=$(mktemp -d -t reset-restore-selftest.XXXXXX) || exit 1
    trap 'rm -rf "$OUT_DIR"' EXIT
    rx() {
        case "$1" in
        'sha256sum config.json')
            [ "$fault" != snapshot ] || return 1
            if [ "$fault" = config ] && [ -e "$OUT_DIR/restored" ]; then printf changed; else printf original; fi
            ;;
        *' backup -y') [ "$fault" != backup ] ;;
        ls*) [ "$fault" != archive ] && printf 'backups/fixture.tar.gz.enc' ;;
        'set -e; test -n '*) [ "$fault" != active ] ;;
        *"printf 'config-reset"*) [ "$fault" != reset ] && touch "$OUT_DIR/reset" ;;
        'test ! -e config.json'*) [ -e "$OUT_DIR/reset" ] && [ "$fault" != absent ] ;;
        *' script -q -e '*)
            [ "$fault" != prompt ] || return 1
            printf 'Backup passphrase: This archive is encrypted'
            return 1
            ;;
        *' restore -y '*) [ "$fault" != restore ] && touch "$OUT_DIR/restored" ;;
        'rm -f -- '*) [ "$fault" != cleanup ] ;;
        *)
            printf '%s\n' "unhandled remote command" >>"$OUT_DIR/unhandled"
            return 127
            ;;
        esac
    }
    pithead() { [ "$fault:$1" != down:down ] && [ "$fault:$1" != up:up ]; }
    upgrade_secret_fingerprints() {
        if [ "$fault" = secrets ] && [ -e "$OUT_DIR/restored" ]; then printf changed; else printf original; fi
    }
    wait_status_ok() { [ "$fault" != health ]; }
    run_reset_restore >"$OUT_DIR/output" 2>&1
    local rc=$?
    [ ! -e "$OUT_DIR/unhandled" ] || rc=127
    printf '%s|%s|%s' "$rc" "$IT_FAIL" "$IT_PASS"
)
assert_eq "healthy reset recovery proves every leg" "$(drive_reset_restore none)" '0|0|8'
for fault in snapshot backup archive active reset absent down prompt restore up health config secrets cleanup; do
    verdict=$(drive_reset_restore "$fault")
    if [[ "$verdict" == 1\|1\|* ]]; then
        it_pass "reset recovery refuses $fault failure"
    else
        it_fail "reset recovery refuses $fault failure" "unexpected verdict $verdict"
    fi
done
[ "$IT_FAIL" -eq 0 ]
