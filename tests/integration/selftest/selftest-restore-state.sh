#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
# shellcheck disable=SC2034
INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-reset-restore.sh"
echo "== restore state refusal and snapshot oracles =="
python3 "$HERE/test_restore_state_probe.py" || exit 1

drive_refusals() (
    local fault="$1"
    # shellcheck disable=SC2034
    IT_FAIL=0 IT_PASS=0 IT_PITHEAD=./pithead
    OUT_DIR=$(mktemp -d) || exit 1
    trap 'rm -rf "$OUT_DIR"' EXIT
    reset_restore_nochange_snapshot() {
        local count
        count=$(cat "$OUT_DIR/count" 2>/dev/null || printf 0)
        echo $((count + 1)) >"$OUT_DIR/count"
        [ "$fault" != snapshot-error ] || return 1
        if [ "$fault" = changed ] && [ "$count" -gt 0 ]; then printf changed; else printf original; fi
    }
    rx() {
        local kind
        if [ "$fault" = wrong-cause ]; then
            printf "unrelated refusal"
            return 1
        fi
        case "$1" in
        *wrong\ reset\ recovery*)
            kind=wrong-passphrase
            printf 'Wrong passphrase or corrupt archive'
            ;;
        *head\ -c\ 1024*)
            kind=truncated
            printf 'Archive fails integrity verification'
            ;;
        *future.tar.gz.enc*)
            kind=newer-config
            printf "This backup's configuration was written by pithead"
            ;;
        *) return 127 ;;
        esac
        [ "$fault" != "$kind-accepted" ] || return 0
        [ "$fault" != "$kind-exit" ] || return 2
        return 1
    }
    reset_restore_refusals fixture.enc >/dev/null 2>&1
    printf '%s|%s|%s' "$?" "$IT_FAIL" "$IT_PASS"
)
assert_eq "all three real restore refusal rows are counted" "$(drive_refusals none)" '0|0|3'
for fault in wrong-passphrase-accepted truncated-accepted newer-config-accepted wrong-passphrase-exit truncated-exit newer-config-exit changed snapshot-error wrong-cause; do
    verdict=$(drive_refusals "$fault")
    if [[ "$verdict" == 1\|1\|* ]]; then
        it_pass "restore refusal oracle rejects $fault"
    else
        it_fail "restore refusal oracle rejects $fault" "$verdict"
    fi
done
for fault in none containers census probe empty; do
    verdict=$(
        reset_restore_state_probe() {
            [ "$fault" != probe ] || return 1
            [ "$fault" = empty ] || printf fingerprint
        }
        rx() {
            [ "$fault" != census ] || return 1
            [ "$fault" != containers ] || printf container
        }
        reset_restore_nochange_snapshot fixture.enc >/dev/null
        printf %s "$?"
    )
    expected=1
    [ "$fault" != none ] || expected=0
    assert_eq "unchanged snapshot rejects $fault failures" "$verdict" "$expected"
done
echo "== restore probe temporary transport =="
drive_temp_transport() (
    local mode="$1" target fixture_root roots_ok=yes scratch_ok=yes rc
    fixture_root=$(mktemp -d) || exit 1
    trap 'chmod 700 "$fixture_root/home"; rm -rf "$fixture_root"' EXIT
    target="$fixture_root/stack"
    mkdir -p "$target" "$fixture_root/bin" "$fixture_root/home" "$fixture_root/temp" "$fixture_root/logs"
    chmod 500 "$fixture_root/home"
    OUT_DIR="$fixture_root/logs"
    # shellcheck disable=SC2034
    IT_FAIL=0 IT_PASS=0 IT_PITHEAD=./pithead
    head -c 4096 /dev/zero >"$target/fixture.enc"
    cat >"$fixture_root/bin/sudo" <<'SH'
#!/usr/bin/env bash
[ "$1" != -n ] || shift
exec "$@"
SH
    cat >"$fixture_root/bin/docker" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat >"$fixture_root/bin/python3" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
[ "$TMPDIR" = "$EXPECTED_TMPDIR" ] || exit 1
printf '%s\n' "$TMPDIR" >>"$ROOTS_LOG"
case "$2" in
snapshot) printf fingerprint ;;
future) printf fixture >"$4" ;;
*) exit 1 ;;
esac
SH
    cat >"$target/pithead" <<'SH'
#!/usr/bin/env bash
case "$PITHEAD_BACKUP_PASSPHRASE:$3" in
'wrong reset recovery fixture:'*) printf 'Wrong passphrase or corrupt archive' ;;
*truncated.tar.gz.enc)
    [ "$(wc -c <"$3")" -eq 1024 ] || exit 2
    printf 'Archive fails integrity verification'
    ;;
*future.tar.gz.enc)
    [ "$(cat "$3")" = fixture ] || exit 2
    printf "This backup's configuration was written by pithead"
    ;;
*) exit 2 ;;
esac
exit 1
SH
    chmod +x "$fixture_root/bin/"* "$target/pithead"
    rx() {
        local temporary_env=(-u TMPDIR) expected_root="$target"
        if [ "$mode" = explicit ]; then
            temporary_env=(TMPDIR="$fixture_root/temp")
            expected_root="$fixture_root/temp"
        fi
        (cd "$target" && env "${temporary_env[@]}" HOME="$fixture_root/home" PATH="$fixture_root/bin:$PATH" EXPECTED_TMPDIR="$expected_root" ROOTS_LOG="$fixture_root/roots" bash -c "$1")
    }
    reset_restore_refusals fixture.enc >"$OUT_DIR/output" 2>&1
    rc=$?
    [ -s "$fixture_root/roots" ] || roots_ok=no
    [ -z "$(find "$target" "$fixture_root/temp" -name 'restore-refusal.*' -print)" ] || scratch_ok=no
    printf '%s|%s|%s|%s|%s' "$rc" "$IT_FAIL" "$IT_PASS" "$roots_ok" "$scratch_ok"
)
assert_eq "unset TMPDIR uses the writable remote working directory with an unwritable home" "$(drive_temp_transport unset)" '0|0|3|yes|yes'
assert_eq "explicit TMPDIR is honored with an unwritable home" "$(drive_temp_transport explicit)" '0|0|3|yes|yes'
[ "$IT_FAIL" -eq 0 ]
