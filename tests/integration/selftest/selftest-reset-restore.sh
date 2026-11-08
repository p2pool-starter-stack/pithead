#!/usr/bin/env bash
# Failure controls for the real encrypted config-reset recovery leg; no engine is started here.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
# shellcheck disable=SC2034 # consumed by the sourced leg
INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-reset-restore.sh"
echo "== encrypted config-reset recovery failure controls =="

drive_dashboard_probe() (
    local fault="$1" rc
    IT_FAIL=0 IT_PASS=0
    OUT_DIR=$(mktemp -d) || exit 1
    trap 'rm -f "$OUT_DIR/probe-ran" "$OUT_DIR/restore-dashboard.log"; rmdir "$OUT_DIR"' EXIT
    rx() {
        case "$1" in
        'sha256sum config.json')
            [ "$fault" != read-config ] || return 1
            if [[ "$fault" = config || "$fault" = probe-and-config ]] && [ -e "$OUT_DIR/probe-ran" ]; then printf changed; else printf original; fi
            ;;
        'bash -s')
            [ "${2:-}" = --stdin ] || return 1
            cat >/dev/null
            : >"$OUT_DIR/probe-ran"
            case "$fault" in probe | probe-and-config) return 1 ;; esac
            ;;
        *) return 127 ;;
        esac
    }
    upgrade_secret_fingerprints() {
        [ "$fault" != read-secrets ] || return 1
        if [ "$fault" = secrets ] && [ -e "$OUT_DIR/probe-ran" ]; then printf changed; else printf original; fi
    }
    env_on_box() {
        [ "$1" = TARI_MODE ] && [ "$fault" != read-tari ] || return 1
        if [ "$fault" = tari ] && [ -e "$OUT_DIR/probe-ran" ]; then printf off; else printf local; fi
    }
    wait_status_ok() { [ "$fault" != health ]; }
    run_restore_dashboard_probe >/dev/null 2>&1
    rc=$?
    printf '%s|%s|%s' "$rc" "$IT_FAIL" "$IT_PASS"
)
assert_eq "dashboard restore probe verifies the original healthy Tari baseline" "$(drive_dashboard_probe none)" '0|0|2'
for fault in read-config read-secrets read-tari; do
    assert_eq "dashboard restore probe refuses $fault before the Tari trial" "$(drive_dashboard_probe "$fault")" '1|1|0'
done
assert_eq "a failed dashboard probe still verifies the original baseline" "$(drive_dashboard_probe probe)" '1|1|1'
assert_eq "a failed dashboard probe also rejects failed cleanup" "$(drive_dashboard_probe probe-and-config)" '1|2|0'
for fault in config secrets tari health; do
    assert_eq "dashboard restore probe refuses changed or unhealthy $fault state" "$(drive_dashboard_probe "$fault")" '1|1|1'
done

drive_reset_restore() (
    local fault="$1" channel="${2:-diy}"
    # shellcheck disable=SC2034 # read by the shared web helper
    IT_SSH_DEST=root@guest.invalid
    # shellcheck disable=SC2034 # consumed by the sourced leg
    IT_FAIL=0 IT_PASS=0 IT_PITHEAD=./pithead
    OUT_DIR=$(mktemp -d -t reset-restore-selftest.XXXXXX) || exit 1
    trap 'rm -rf "$OUT_DIR"' EXIT
    echo 0 >"$OUT_DIR/clock"
    date() { cat "$OUT_DIR/clock"; }
    now_s() { cat "$OUT_DIR/clock"; }
    sleep() { echo $(($(now_s) + ${1:-2})) >"$OUT_DIR/clock"; }
    env_on_box() {
        [ "$fault" != "env-$1" ] || return 1
        case "$1" in
        HOST_IP) printf dashboard.invalid ;;
        HOST_PORT) case "$fault" in custom-port | custom-http) printf 8443 ;; esac ;;
        DASHBOARD_SECURE) if [ "$fault" = custom-http ]; then printf false; else printf true; fi ;;
        DASHBOARD_AUTH_HASH_B64) [ "$fault" = noauth ] || printf fixture ;;
        esac
        return 0
    }
    curl() { [ "$fault" != page ] && printf 'Pithead setup'; }
    rr_restore_during_wizard_startup() { :; }
    reset_restore_wait_reboot() { :; }

    rx() {
        case "$1" in
        'sha256sum config.json')
            [ "$fault" != snapshot ] || return 1
            if [ "$fault" = config ] && [ -e "$OUT_DIR/restored" ]; then printf changed; else printf original; fi
            ;;
        *' backup -y') [ "$fault" != backup ] ;;
        'cat /proc/sys/kernel/random/boot_id') printf boot-a ;;
        *"inspect --format '{{.State.Running}}' pithead-wizard") [ "$fault" != wizard-start ] && printf true ;;
        'docker ps -a --format "{{.Names}}"')
            [ "$fault" != wizard ] || printf pithead-wizard
            ;;
        *"inspect --format '{{.Id}} {{.RestartCount}}"*)
            local count=0 started=start-a id=caddy-a health=healthy
            if [ "$(now_s)" -gt 0 ]; then
                [ "$fault" != restart ] || count=1
                [ "$fault" != started ] || started=start-b
                [ "$fault" != id ] || id=caddy-b
            fi
            [ "$fault" != starting ] || health=starting
            printf '%s %s %s true %s' "$id" "$count" "$started" "$health"
            ;;
        'source ./pithead || exit;'*)
            [ "$fault" != channel ] || return 255
            printf '%s' "$channel"
            ;;
        curl*)
            [ "$fault" != curl ] || return 1
            local port=443
            local scheme=https
            case "$fault" in custom-port | custom-http) port=8443 ;; esac
            [ "$fault" != custom-http ] || scheme=http
            [[ "$1" == *"--resolve dashboard.invalid:$port:127.0.0.1"* ]] &&
                [[ "$1" == *"$scheme://dashboard.invalid:$port/"* ]] || return 127
            local body=dashboard code=401
            [ "$fault" != body ] || body='Pithead setup'
            [ "$fault" != zero ] || code=000
            [ "$fault" != code ] || code=503
            [ "$fault" != noauth ] || code=200
            printf '%s\n%s' "$body" "$code"
            ;;
        'ss -ltnp; docker logs --tail 40 caddy') : ;;

        ls*) [ "$fault" != archive ] && printf 'backups/fixture.tar.gz.enc' ;;
        'set -e; stage=census;'*)
            printf '%s' "$1" >"$OUT_DIR/probe"
            case "$fault" in
            active) return 1 ;;
            refused)
                printf 'restore exit=1 running=7 first-line=[ERROR] Restore could not verify that the stack is stopped\npresent after restore:\nstack intact\nconfigless census stderr=[]\n' >&2
                return 1
                ;;
            other)
                printf 'restore exit=1 running=7 first-line=[ERROR] Not a pithead backup archive\npresent after restore:\nstack intact\nconfigless census stderr=[]\n' >&2
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
        *"printf 'config-reset"*)
            [ "$fault" != reset ] || return 1
            touch "$OUT_DIR/reset"
            case "$fault" in
            warning) printf 'Stack shutdown failed — continuing with the config wipe.\n' ;;
            old-warning) printf 'compose down failed (engine not running?) — continuing with the config wipe.\n' ;;
            esac
            [ "$channel" != appliance ] || printf 'Rebooting into first-boot'
            ;;
        'docker ps --all --quiet --filter label=com.docker.compose.project=pithead')
            case "$fault" in
            residue) printf 'exited-container\n' ;;
            census) return 1 ;;
            esac
            ;;
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
    run_reset_restore_fixture >"$OUT_DIR/output" 2>&1
    local rc=$?
    [ ! -e "$OUT_DIR/unhandled" ] || rc=127
    if [ "$fault" = none ]; then cp "$OUT_DIR/probe" "$PROBE_COPY"; fi
    printf '%s|%s|%s' "$rc" "$IT_FAIL" "$IT_PASS"
    case "$fault" in refused | written | stopped | other)
        printf '|intact=%s|%s' "${RESET_RESTORE_STACK_INTACT:-0}" "$(grep -c '#3346' "$OUT_DIR/output")"
        ;;
    residue | census)
        printf '|%s|elapsed=%s' "$(tail -n 1 "$OUT_DIR/output")" "$(now_s)"
        ;;
    esac
)
PROBE_COPY=$(mktemp -t reset-restore-probe.XXXXXX) || exit 1
trap 'rm -f "$PROBE_COPY"' EXIT
assert_eq "healthy reset recovery proves every leg" "$(drive_reset_restore none)" '0|0|13'
assert_eq "appliance recovery proves the setup-page trigger and web ownership" "$(drive_reset_restore none appliance)" '0|0|14'
assert_eq "custom HTTPS port is used by both URL and resolve" "$(drive_reset_restore custom-port)" '0|0|13'
assert_eq "custom HTTP port is used by both URL and resolve" "$(drive_reset_restore custom-http)" '0|0|13'
assert_eq "DIY without auth expects HTTP 200" "$(drive_reset_restore noauth)" '0|0|13'
for fault in page wizard restart started id starting body zero curl code noauth wizard-start channel env-HOST_PORT env-DASHBOARD_SECURE env-DASHBOARD_AUTH_HASH_B64; do
    verdict=$(drive_reset_restore "$fault" appliance)
    if [[ "$verdict" == 1\|1\|* ]]; then
        it_pass "appliance recovery refuses $fault web failure"
    else
        it_fail "appliance recovery refuses $fault web failure" "unexpected verdict $verdict"
    fi
done
# Restore refused and wrote nothing: the failure names #3346 and lets later phases run; a write does not.
assert_eq "a refusal that wrote nothing fails the row, names #3346 and flags the stack intact" \
    "$(drive_reset_restore refused)" "1|1|1|intact=1|1"
assert_eq "a restore that wrote a file fails the row and does not flag the stack intact" \
    "$(drive_reset_restore written)" "1|1|1|intact=0|0"
assert_eq "a different refusal is not labelled as #3346 but still flags the stack intact" \
    "$(drive_reset_restore other)" "1|1|1|intact=1|0"
assert_eq "a restore that left no container running does not flag the stack intact" \
    "$(drive_reset_restore stopped)" "1|1|1|intact=0|0"
# Run the real probe text against a fake docker and pithead: the stage report, the intact marker and
# the restoring trap are probe behaviour that the stubbed fixtures above cannot see.
run_probe() { # <restore-exit> <restore-writes-config:0|1> <running-before> <running-after>
    local d
    d=$(mktemp -d -t reset-restore-probe-run.XXXXXX) || return 1
    mkdir "$d/bin" "$d/work"
    printf '%s\n' '#!/bin/bash' 'n=$(cat "$PROBE_DIR/n")' 'for _ in $(seq "$n"); do echo c; done' 'echo 1 >"$PROBE_DIR/seen"' >"$d/bin/docker"
    printf '%s\n' '#!/bin/bash' 'echo "[ERROR] Restore could not verify that the stack is stopped"' '[ "$WRITES" != 1 ] || echo x >config.json' 'echo "$AFTER" >"$PROBE_DIR/n"' 'exit "$RESTORE_RC"' >"$d/work/pithead"
    chmod +x "$d/bin/docker" "$d/work/pithead"
    echo "$3" >"$d/n"
    : >"$d/work/config.json"
    : >"$d/work/.env"
    : >"$d/work/Caddyfile"
    # shellcheck disable=SC2069 # stderr only, as the rx caller captures it
    (cd "$d/work" && PROBE_DIR="$d" RESTORE_RC="$1" WRITES="$2" AFTER="$4" PATH="$d/bin:$PATH" env -u TMPDIR bash -c "$(cat "$PROBE_COPY")" 2>&1 >/dev/null)
    printf 'rc=%s files=%s\n' "$?" "$(cd "$d/work" && for f in config.json .env Caddyfile; do [ -e "$f" ] && printf '%s ' "$f"; done)"
    rm -rf "$d"
}
out=$(run_probe 1 0 7 7)
assert_contains "the probe marks a refusal that changed nothing intact and restores every file" "$out" "stack intact"
assert_contains "the probe restores the hidden files on exit" "$out" "files=config.json .env Caddyfile"
out=$(run_probe 1 0 7 3)
if [[ "$out" == *"stack intact"* ]]; then it_fail "the probe withholds intact when containers stopped" "$out"; else it_pass "the probe withholds intact when containers stopped"; fi
out=$(run_probe 1 1 7 7)
if [[ "$out" == *"stack intact"* ]]; then it_fail "the probe withholds intact when a file was written" "$out"; else it_pass "the probe withholds intact when a file was written"; fi
out=$(run_probe 0 0 7 7)
assert_contains "the probe fails a restore that exits 0" "$out" "restore exited 0"
out=$(run_probe 1 0 0 0)
assert_contains "the probe names the census stage when nothing runs" "$out" "failed at census"
# An SSH session on a stock guest has no TMPDIR: the probe's scratch directory must still resolve.
bash -n "$PROBE_COPY" || it_fail "reset-restore probe parses" "syntax error"
scratch_line=$(grep -m1 'mktemp -d' "$PROBE_COPY")
if scratch=$(env -u TMPDIR bash -c "set -e; ${scratch_line%;}; printf %s \"\$scratch\"; rmdir \"\$scratch\"") && [[ "$scratch" == /tmp/reset-restore.* ]]; then
    it_pass "reset-restore probe creates its scratch directory without TMPDIR"
else
    it_fail "reset-restore probe creates its scratch directory without TMPDIR" "scratch line failed: $scratch_line"
fi
# The appliance reboots on config-reset: the wait must see a new boot id, and must give up if none comes.
(
    sleep() { :; }
    calls=$(mktemp) || exit 1
    rx() {
        echo x >>"$calls"
        n=$(wc -l <"$calls")
        if [ "$n" -lt 3 ]; then return 255; elif [ "$n" -lt 4 ]; then printf boot-a; else printf boot-b; fi
    }
    reset_restore_wait_reboot boot-a 60
) && it_pass "reboot wait returns once a new boot id answers" || it_fail "reboot wait returns once a new boot id answers" "never saw boot-b"
(
    clock=$(mktemp) || exit 1
    echo 0 >"$clock"
    sleep() { echo $(($(cat "$clock") + 30)) >"$clock"; }
    date() { cat "$clock"; }
    rx() { printf boot-a; }
    reset_restore_wait_reboot boot-a 60
) && it_fail "reboot wait gives up when the boot id never changes" "returned success" || it_pass "reboot wait gives up when the boot id never changes"
for fault in snapshot backup archive active reset absent down prompt restore up health config secrets cleanup warning old-warning residue census; do
    verdict=$(drive_reset_restore "$fault")
    if [[ "$verdict" == 1\|1\|* ]]; then
        it_pass "reset recovery refuses $fault failure"
    else
        it_fail "reset recovery refuses $fault failure" "unexpected verdict $verdict"
    fi
done
for channel in diy appliance; do
    assert_contains "$channel reset residue failure names the exited container after the bounded wait" \
        "$(drive_reset_restore residue "$channel")" \
        'project residue or engine read failure before configless down: exited-container|elapsed=60'
    assert_contains "$channel reset census failure reports an unreadable engine after the bounded wait" \
        "$(drive_reset_restore census "$channel")" \
        'project residue or engine read failure before configless down: unreadable|elapsed=60'
done
if reset_restore_shutdown_clean "$PROBE_COPY.absent" 2>/dev/null; then
    it_fail "missing reset log cannot pass the warning guard" "reader error accepted"
else
    it_pass "missing reset log cannot pass the warning guard"
fi
# The real status predicate needs two matching censuses, resets on failed status and read errors,
# and treats a recreated container like a restart. No fake predicate replaces the code under test.
(
    status_churn_reset
    census='id start-a 0'
    pithead() { [ "${status_fails:-0}" = 0 ]; }
    rx() {
        case "$1" in
        'docker ps -aq '*) printf id ;;
        'docker inspect '*) [ "${inspect_fails:-0}" = 0 ] && printf '%s' "$census" ;;
        *) return 127 ;;
        esac
    }
    _pred_status_ok && exit 1
    _pred_status_ok || exit 1
    for census in 'id start-b 0' 'id start-b 1' 'new-id start-b 1'; do
        _pred_status_ok && exit 1
        _pred_status_ok || exit 1
    done
    status_fails=1
    _pred_status_ok && exit 1
    status_fails=0
    _pred_status_ok && exit 1
    _pred_status_ok || exit 1
    inspect_fails=1
    _pred_status_ok && exit 1
    inspect_fails=0
    _pred_status_ok && exit 1
    _pred_status_ok || exit 1
    # Each wait clears any prior success: its first read must not reuse a stale census.
    wait_for() {
        "$4" && exit 1
        "$4"
    }
    wait_status_ok || exit 1
) && it_pass "status waits reject churn and require consecutive OK reads" ||
    it_fail "status waits reject churn and require consecutive OK reads" "predicate accepted churn or stale state"
[ "$IT_FAIL" -eq 0 ]
