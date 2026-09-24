#!/usr/bin/env bash
# The readiness row `stack is healthy (pithead status)` waits for health to settle and, when it
# never does, names the unhealthy service (#2656). Job 949 failed the one-shot read where 973
# passed at the same commit, and the discarded output left no container to blame.
#
# The shipped assert_release_readiness runs against a stubbed box on a fake clock: `sleep` moves
# the clock, and the stubbed `pithead status` turns healthy once the clock reaches HEALTHY_AT.
# The real wait_for, it_fail and redact from lib.sh are used.
#
# Proven able to fail: with the row reverted to the one-shot `pithead status >/dev/null 2>&1` plus
# `assert_rc`, 7 rows go red (the settles-after-60s rows, the bound and the detail rows); with
# status_verdict_lines reduced to plain `redact`, 3 go red (colour, the password/onion/compose-table
# row, and the empty-output row); without its `redact`, the two address rows go red.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

echo "== readiness health row waits, then names the unhealthy service (#2656) =="

MODULE="$HERE/../lib/run-scenario.sh"
READINESS_SRC="$(sed -n '/^_pred_readiness_status() {/p; /^status_verdict_lines() {/p; /^assert_release_readiness() {$/,/^}$/p' "$MODULE")"
assert_contains "the extraction has the status predicate" "$READINESS_SRC" "_pred_readiness_status() {"
assert_contains "the extraction has the verdict filter" "$READINESS_SRC" "status_verdict_lines() {"
assert_eq "the extraction ends with the whole readiness function" \
    "$(printf '%s\n' "$READINESS_SRC" | sed -n '/^assert_release_readiness() {$/p;$p' | tr '\n' ' ')" "assert_release_readiness() { } "

SECRET_PASS="readiness-selftest-stratum-pass"
drive_readiness() { # <healthy-at-second|never> -> "fails=<n> clock=<s>" then the row output
    (
        # shellcheck disable=SC2034 # IT_FAIL/IT_PASS are read after the eval'd function returns
        IT_FAIL=0 IT_PASS=0 FAKE_NOW=0 HEALTHY_AT="$1" IT_GREEN='' IT_RED='' IT_RESET=''
        now_s() { printf '%s' "$FAKE_NOW"; }
        sleep() { FAKE_NOW=$((FAKE_NOW + $1)); }
        monero_caught_up() { return 0; }
        api_state() { printf '{}'; }
        jq_get() { printf 'done'; }
        env_on_box() { :; }
        box_mode() { printf 600; }
        rx() { return 0; }
        it_log() { :; }
        it_warn() { :; }
        pithead() {
            [ "$1" = status ] || return 2
            if [ "$HEALTHY_AT" != never ] && [ "$FAKE_NOW" -ge "$HEALTHY_AT" ]; then
                printf '  ✓ tor           running\n[pithead] All expected services are up.\n'
                return 0
            fi
            printf 'NAME  IMAGE  STATUS\ntor   tor    Up 2 minutes (unhealthy)\n\n'
            printf '[pithead] Service health check:\n'
            printf '  \033[1;32m✓\033[0m monerod       running\n'
            printf '  ⚠ tor           running but UNHEALTHY\n'
            printf '[pithead] Stratum authentication is ON: every rig must connect with pass "%s"\n' "$SECRET_PASS"
            printf '[pithead] Dashboard onion (remote access): http://%s.onion (login required)\n' "$(printf 'a%.0s' {1..56})"
            printf '[WARNING] 1 service(s) need attention (see above).\n'
            printf '[WARNING] tor cannot reach its guard at 203.0.113.9\n'
            return 1
        }
        eval "$READINESS_SRC"
        out="$(mktemp)"
        assert_release_readiness >"$out" 2>&1
        printf 'fails=%s clock=%s\n%s' "$IT_FAIL" "$FAKE_NOW" "$(cat "$out")"
        rm -f "$out"
    )
}
row_of() { awk '/stack is healthy \(pithead status\)/ { on = 1; print; next } on && /^    [^ ]/ { exit } on' <<<"$1"; }

HEALTHY_NOW="$(drive_readiness 0)"
assert_eq "a healthy stack passes on the first read" "$(head -n1 <<<"$HEALTHY_NOW")" "fails=0 clock=0"
assert_contains "the healthy row is a pass" "$HEALTHY_NOW" "✓ stack is healthy (pithead status)"

SETTLES="$(drive_readiness 60)"
assert_eq "a stack that settles within the bound passes the whole readiness run" "$(head -n1 <<<"$SETTLES")" "fails=0 clock=60"
assert_contains "the settled row is a pass" "$SETTLES" "✓ stack is healthy (pithead status)"

STAYS="$(drive_readiness never)"
STAYS_ROW="$(row_of "$STAYS")"
assert_eq "a stack that stays unhealthy fails one row" "$(head -n1 <<<"$STAYS" | cut -d' ' -f1)" "fails=1"
CLOCK="$(head -n1 <<<"$STAYS" | sed 's/.*clock=//')"
if [ "$CLOCK" -ge 240 ] && [ "$CLOCK" -lt 250 ]; then
    it_pass "the unhealthy verdict waits out the 240s bound (clock ${CLOCK}s)"
else
    it_fail "the unhealthy verdict waits out the 240s bound" "clock ${CLOCK}s"
fi
assert_contains "the failed row is the health row" "$STAYS_ROW" "✗ stack is healthy (pithead status)"
assert_contains "the detail states the bound" "$STAYS_ROW" "still unhealthy after 240s"
assert_contains "the detail names the unhealthy service" "$STAYS_ROW" "        ⚠ tor           running but UNHEALTHY"
assert_contains "the detail carries the status warning" "$STAYS_ROW" "[WARNING] 1 service(s) need attention"
assert_contains "the detail redacts an address in a kept line" "$STAYS_ROW" "[WARNING] tor cannot reach its guard at <redacted-ip>"
assert_contains "the detail keeps the healthy services, colour stripped" "$STAYS_ROW" "        ✓ monerod       running"
case "$STAYS_ROW" in
*"$SECRET_PASS"* | *.onion* | *$'\033'* | *"IMAGE  STATUS"* | *203.0.113.9*)
    it_fail "the detail leaves out the password, the onion, colour codes and the compose table" "$STAYS_ROW"
    ;;
*) it_pass "the detail leaves out the password, the onion, colour codes and the compose table" ;;
esac

EMPTY="$(printf 'ssh: connect failed\n' | (eval "$READINESS_SRC" && status_verdict_lines))"
assert_eq "output without service lines yields no verdict lines" "$EMPTY" ""
ERRORED="$(printf '[ERROR] No .env found. Run ./pithead apply first.\n' | (eval "$READINESS_SRC" && status_verdict_lines))"
assert_eq "a status that errors out keeps its error line" "$ERRORED" "[ERROR] No .env found. Run ./pithead apply first."

echo "selftest-readiness-status: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
