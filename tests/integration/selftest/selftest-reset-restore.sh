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
        'set -e; stage=census;'*)
            printf '%s' "$1" >"$OUT_DIR/probe"
            case "$fault" in
            active) return 1 ;;
            refused)
                printf 'restore exit=1 running=7 first-line=x\npresent after restore:\nconfigless census stderr=[]\n' >&2
                return 1
                ;;
            stopped)
                printf 'restore exit=1 running=0 first-line=x\npresent after restore:\n' >&2
                return 1
                ;;
            written)
                printf 'restore exit=1 running=7 first-line=x\npresent after restore: config.json\n' >&2
                return 1
                ;;
            esac
            ;;
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
    if [ "$fault" = none ]; then cp "$OUT_DIR/probe" "$PROBE_COPY"; fi
    printf '%s|%s|%s' "$rc" "$IT_FAIL" "$IT_PASS"
    case "$fault" in refused | written | stopped)
        printf '|intact=%s|%s' "${RESET_RESTORE_STACK_INTACT:-0}" "$(grep -c '#3346' "$OUT_DIR/output")"
        ;;
    esac
)
PROBE_COPY=$(mktemp -t reset-restore-probe.XXXXXX) || exit 1
trap 'rm -f "$PROBE_COPY"' EXIT
assert_eq "healthy reset recovery proves every leg" "$(drive_reset_restore none)" '0|0|8'
# Restore refused and wrote nothing: the failure names #3346 and lets later phases run; a write does not.
assert_eq "a refusal that wrote nothing fails the row, names #3346 and flags the stack intact" \
    "$(drive_reset_restore refused)" "1|1|1|intact=1|1"
assert_eq "a restore that wrote a file fails the row and does not flag the stack intact" \
    "$(drive_reset_restore written)" "1|1|1|intact=0|0"
assert_eq "a restore that left no container running does not flag the stack intact" \
    "$(drive_reset_restore stopped)" "1|1|1|intact=0|0"
# An SSH session on a stock guest has no TMPDIR: the probe's scratch directory must still resolve.
bash -n "$PROBE_COPY" || it_fail "reset-restore probe parses" "syntax error"
scratch_line=$(grep -m1 'mktemp -d' "$PROBE_COPY")
if scratch=$(env -u TMPDIR bash -c "set -e; ${scratch_line%;}; printf %s \"\$scratch\"; rmdir \"\$scratch\"") && [[ "$scratch" == /tmp/reset-restore.* ]]; then
    it_pass "reset-restore probe creates its scratch directory without TMPDIR"
else
    it_fail "reset-restore probe creates its scratch directory without TMPDIR" "scratch line failed: $scratch_line"
fi
for fault in snapshot backup archive active reset absent down prompt restore up health config secrets cleanup; do
    verdict=$(drive_reset_restore "$fault")
    if [[ "$verdict" == 1\|1\|* ]]; then
        it_pass "reset recovery refuses $fault failure"
    else
        it_fail "reset recovery refuses $fault failure" "unexpected verdict $verdict"
    fi
done
[ "$IT_FAIL" -eq 0 ]
