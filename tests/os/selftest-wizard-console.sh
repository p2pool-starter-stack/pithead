#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/pithead/12a-wizard-addresses.sh
source "${WIZARD_ADDRESSES_SOURCE:-$ROOT/lib/pithead/12a-wizard-addresses.sh}"
# shellcheck source=tests/os/wizard-console-leg.sh
source "$ROOT/tests/os/wizard-console-leg.sh"
wizard_issue_file() { printf '%s/issue.d/pithead-setup.issue' "$work"; }
hostname() { printf fixture; }
log() { printf '%s\n' "$*" >>"$work/journal"; }
agetty() {
    [ "$1" = --reload ]
    printf 'reload\n' >>"$work/reloads"
}
wizard_announce_setup '192.0.2.1 2001:db8::1' pit-ABC123 fingerprint
issue=$(wizard_issue_file)
[ "$(stat -c %a "$issue")" = 600 ]
wizard_console_details_present "$issue" pit-ABC123 fixture
grep -Fq 'https://192.0.2.1' "$issue"
grep -Fq 'SHA-256: fingerprint' "$issue"
grep -Fq 'https://[2001:db8::1]' "$work/journal"
[ "$(cat "$work/reloads")" = reload ]
echo 'PASS: private complete banner published before getty reload'
wizard_announce_setup '2001:db8::2' pit-DEF456 ''
! grep -Fq pit-ABC123 "$issue"
grep -Fq 'http://[2001:db8::2]' "$issue"
! grep -Fq SHA-256 "$issue"
! wizard_console_details_present "$issue" pit-ABC123 fixture
printf 'One-time token: pit-DEF456\nhttp://fixture.local\n' >"$work/http-console"
wizard_console_details_present "$work/http-console" pit-DEF456 fixture
! wizard_console_details_present /nonexistent pit-DEF456 fixture
echo 'PASS: new sessions replace the old token, scheme and certificate'
(
    mktemp() { return 1; }
    ! wizard_announce_setup '' pit-GHI789 ''
)
grep -Fq pit-DEF456 "$issue"
(
    mv() { return 1; }
    ! wizard_announce_setup '' pit-GHI789 ''
)
[ "$(find "$work/issue.d" -type f | wc -l | tr -d ' ')" = 1 ]
grep -Fq pit-DEF456 "$issue"
echo 'PASS: failed publication keeps the complete previous banner and removes temporary files'
(
    rm() { return 1; }
    ! wizard_clear_announcement
)
[ -f "$issue" ]
wizard_clear_announcement
[ ! -e "$issue" ]
echo 'PASS: cleanup removes the token and reports removal failures'
for unit in pithead-firstboot pithead-setup-again; do
    grep -Fxq 'ExecStopPost=-/usr/bin/rm -f /run/issue.d/pithead-setup.issue' "$ROOT/os/overlay/$unit.service"
done
echo 'PASS: both wizard services also remove the banner when systemd stops them'
_ssh() { printf '%s' "$journal_token"; }
sleep() { :; }
ok() { printf '%s\n' "$*" >>"$work/verdicts"; }
bad() { printf '%s\n' "$*" >>"$work/verdicts"; }
journal_token=pit-ABC123
_setup_again_journal_token
[ "$SA_JOURNAL_TOKEN" = pit-ABC123 ]
for journal_token in '' stale 'pit-ABC123 pit-DEF456'; do
    ! _setup_again_journal_token
done
! grep -Fq pit-ABC123 "$work/verdicts"
printf 'One-time token: pit-ABC123\nhttps://fixture.local\n' >"$work/console"
wizard_console_details_present "$work/console" pit-ABC123 fixture
! wizard_console_details_present "$work/console" pit-DEF456 fixture
! wizard_console_details_present "$work/console" pit-ABC123 other
printf 'One-time token: pit-ABC123\n' >"$work/console"
! wizard_console_details_present "$work/console" pit-ABC123 fixture
echo 'PASS: minting and console verdicts reject missing, stale and mismatched session details'

SERIAL="$work/serial"
SCRIPT_DIR="$ROOT/tests/os"
token=pit-ABC123
_ssh() {
    case "$*" in
    *'touch /run/pithead-console-race/release '*)
        printf 'cleanup\n' >>"$work/cleanup"
        [ "$scenario" != cleanup-failed ]
        ;;
    *'cat >/run/pithead-console-race/writer.sh'*) command cat >/dev/null ;;
    *'test -e /run/pithead-console-race/ready'*) [ "$scenario" != no-writer ] ;;
    *'systemctl restart '*)
        [ "$scenario" != restart-failed ] || return 1
        printf 'fixture login:\n' >>"$SERIAL"
        if [ "$mode" = published ]; then
            if [ "$scenario" = stale ]; then
                printf 'https://fixture.local One-time token: pit-DEF456\n' >>"$SERIAL"
            else
                printf 'https://fixture.local One-time token: pit-ABC123\n' >>"$SERIAL"
            fi
        fi
        ;;
    'cat /dev/vcs1')
        [ "$scenario" != unreadable-monitor ] || return 1
        printf 'fixture login:\n'
        if [ "$mode" = published ]; then printf 'https://fixture.local One-time token: pit-ABC123\n'; fi
        ;;
    *) return 0 ;;
    esac
}
for scenario in success stale unreadable-monitor no-writer cleanup-failed; do
    printf 'https://fixture.local One-time token: pit-ABC123\n' >"$SERIAL"
    if _setup_again_console_race published "$work/race" fixture >"$work/race-capture"; then
        [ "$scenario" = success ]
    else
        [ "$scenario" != success ]
    fi
done
scenario=success
_setup_again_console_race control "$work/control" fixture >"$work/control-capture"
scenario=restart-failed
! _setup_again_console_race control "$work/control" fixture >"$work/failed-control-capture"
[ "$(wc -l <"$work/cleanup" | tr -d ' ')" = 7 ]
echo 'PASS: race proof rejects stale captures, failed gettys, absent writers and missing monitor reads, and always cleans up'

wizard_console_record_capture fixture "$work/http-console" >"$work/capture.log"
grep -Fxq 'BEGIN setup-console fixture' "$work/capture.log"
grep -Fxq 'END setup-console fixture' "$work/capture.log"
grep -Fq 'One-time token: pit-DEF456' "$work/capture.log"
head -c 65537 /dev/zero >"$work/oversize"
! wizard_console_record_capture oversize "$work/oversize" >"$work/oversize.log"
[ ! -s "$work/oversize.log" ]
! wizard_console_record_capture missing "$work/missing" >"$work/missing.log"
echo 'PASS: bounded console captures reach the collected harness log and unavailable captures fail'
