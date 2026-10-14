#!/usr/bin/env bash
#
# Self-test for the live alert-egress leg (run-alert-egress.sh, #2266), driven as pure functions
# against stubs — no bench, no docker, no Tor.
#
# The behaviour this file exists to pin: (1) a sink with no operator credential self-skips in the
# "missing" class and NAMES the sink, never a silent pass; (2) a third-party FAIL from test-alert
# (or a rejected Healthchecks ping) is a REFUSAL — counted on its own — and must NEVER become an
# IT_FAIL, which is the whole point of #2266 (a stuck Tor guard is an environment fact, not our
# regression); (3) a sink test-alert reports "not configured" for, after this leg just configured
# it, IS our bug and must fail loudly.
#
# Counts are SNAPSHOTTED into plain vars right after the call under test, before any assert_eq of
# this file's own runs — assert_eq itself calls it_pass/it_fail on the SAME global counters, so
# checking $IT_PASS a second time after an earlier assert_eq already moved it would be testing
# this file, not the leg.
#
# Standalone (not sourced by selftest.sh), same reasoning as the other run-*.sh self-tests.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-alert-egress.sh
source "$HERE/../lib/run-alert-egress.sh"

BASELINE_CONFIG='{"telegram":{},"notifications":{"ntfy":{},"webhooks":[]},"healthchecks":{}}'
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

push_config() { :; }
pithead() { :; }
wait_status_ok() { return 0; }
STUB_TEST_ALERT_OUT=""
STUB_HC_RC=0
rx() {
    case "$1" in
    *test_alert*) printf '%s' "$STUB_TEST_ALERT_OUT" ;;
    *HealthchecksClient*) return "$STUB_HC_RC" ;;
    *) : ;;
    esac
}

reset_counters() {
    IT_PASS=0 IT_FAIL=0 IT_FAILED_NAMES=""
    IT_SKIPPED=0 IT_SKIPPED_LEGS=0 IT_SKIPPED_MISSING=0 IT_SKIPPED_NAMES=""
    IT_ALERT_REFUSED=0 IT_ALERT_REFUSED_NAMES=""
    unset IT_TELEGRAM_BOT_TOKEN IT_TELEGRAM_CHAT_ID IT_NTFY_URL IT_WEBHOOK_URLS IT_HEALTHCHECKS_PING_URL
}

echo "== no credentials: every sink self-skips missing, named, and nothing dials out =="
reset_counters
run_alert_egress_smoke >/dev/null 2>&1
skipped_legs=$IT_SKIPPED_LEGS missing=$IT_SKIPPED_MISSING pass=$IT_PASS fail=$IT_FAIL refused=$IT_ALERT_REFUSED
names="$(echo -e "$IT_SKIPPED_NAMES")"
assert_eq "four sinks skipped" "$skipped_legs" "4"
assert_eq "all four counted missing" "$missing" "4"
assert_eq "no pass" "$pass" "0"
assert_eq "no fail" "$fail" "0"
assert_eq "no refusal" "$refused" "0"
assert_contains "Telegram named in the skip list" "$names" "IT_TELEGRAM_BOT_TOKEN"
assert_contains "Healthchecks named in the skip list" "$names" "IT_HEALTHCHECKS_PING_URL"

echo "== Telegram configured, sink PASSes: a real pass, not a refusal =="
reset_counters
export IT_TELEGRAM_BOT_TOKEN=tok IT_TELEGRAM_CHAT_ID=chat
STUB_TEST_ALERT_OUT=$'Telegram: PASS\nWebhook: not configured\nntfy: not configured\nHealthchecks: excluded — a ping moves the dead-man switch.'
run_alert_egress_smoke >/dev/null 2>&1
pass=$IT_PASS refused=$IT_ALERT_REFUSED fail=$IT_FAIL
assert_eq "Telegram passed" "$pass" "1"
assert_eq "no refusal" "$refused" "0"
assert_eq "no fail" "$fail" "0"

echo "== Telegram configured, third party FAILs: a REFUSAL, never IT_FAIL (#424) =="
reset_counters
export IT_TELEGRAM_BOT_TOKEN=tok IT_TELEGRAM_CHAT_ID=chat
STUB_TEST_ALERT_OUT=$'Telegram: FAIL (HTTP error)\nWebhook: not configured\nntfy: not configured\nHealthchecks: excluded — a ping moves the dead-man switch.'
run_alert_egress_smoke >/dev/null 2>&1
fail=$IT_FAIL refused=$IT_ALERT_REFUSED
refused_names="$(echo -e "$IT_ALERT_REFUSED_NAMES")"
assert_eq "no fail — a third-party refusal must never redden the gate" "$fail" "0"
assert_eq "one refusal counted" "$refused" "1"
assert_contains "refusal names the leg and the reason" "$refused_names" "HTTP error"

echo "== Telegram configured, test-alert still reports it unconfigured: OUR bug, a real fail =="
reset_counters
export IT_TELEGRAM_BOT_TOKEN=tok IT_TELEGRAM_CHAT_ID=chat
STUB_TEST_ALERT_OUT=$'Telegram: not configured\nWebhook: not configured\nntfy: not configured\nHealthchecks: excluded — a ping moves the dead-man switch.'
run_alert_egress_smoke >/dev/null 2>&1
fail=$IT_FAIL refused=$IT_ALERT_REFUSED
assert_eq "a sink we just configured reporting unconfigured is our bug" "$fail" "1"
assert_eq "no refusal" "$refused" "0"

echo "== Healthchecks configured, ping rejected: a REFUSAL, never IT_FAIL =="
reset_counters
export IT_HEALTHCHECKS_PING_URL=https://hc.invalid/x
STUB_HC_RC=1
run_alert_egress_smoke >/dev/null 2>&1
fail=$IT_FAIL refused=$IT_ALERT_REFUSED
assert_eq "no fail" "$fail" "0"
assert_eq "one refusal" "$refused" "1"

echo "== Healthchecks configured, ping answers: a pass =="
reset_counters
export IT_HEALTHCHECKS_PING_URL=https://hc.invalid/x
STUB_HC_RC=0
run_alert_egress_smoke >/dev/null 2>&1
pass=$IT_PASS refused=$IT_ALERT_REFUSED
assert_eq "Healthchecks passed" "$pass" "1"
assert_eq "no refusal" "$refused" "0"

echo "selftest-alert-egress: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
