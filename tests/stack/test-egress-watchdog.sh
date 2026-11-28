# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

eau_set() {
    jq -n --argjson w "$1" --argjson a "$2" --argjson c "$3" \
        '{nftables: [{rule: {comment: "would_drop", expr: [{counter: {packets: $w, bytes: 0}}]}},
        {rule: {comment: "allowlisted", expr: [{counter: {packets: $a, bytes: 0}}]}},
        {rule: {comment: "choice", expr: [{counter: {packets: $c, bytes: 0}}]}}]}' >"$EAU/json"
}
echo "== egress-status: the watchdog compares would_drop across consecutive checks (#4385) =="
eau_wd() { jq -c "$1" "$EAU/ctl/results/egress-status.json"; }
rm -f "$EAU/ctl/results/.egress-audit-prev"
cp "$EAU/json" "$EAU/json.base"
eau_status egress_status >/dev/null
assert_eq "a first check has no baseline, so it is clean, never a leak" "$(eau_wd .host_audit.watchdog)" '"clean"'
assert_eq "and it records the counter as the baseline" "$(cat "$EAU/ctl/results/.egress-audit-prev")" "55 - 0 0"
out=$(eau_status egress_status)
assert_contains "an unchanged counter stays clean" "$out" "watchdog=clean (rise 0 since the last check)"
cp "$EAU/counter-rising.json" "$EAU/json"
out=$(eau_status egress_status)
assert_contains "a rising counter is non-Tor egress seen, with the rise" "$out" "watchdog=leaking (rise 25 since the last check)"
assert_eq "the status file carries the verdict, the rise, the count and the time first seen" \
    "$(eau_wd '[.host_audit.watchdog, .host_audit.watchdog_delta, .host_audit.would_drop, .host_audit.first_seen == .checked_at]')" \
    '["leaking",25,80,true]'
assert_contains "doctor shows the watchdog verdict" "$(eau_status check_host_egress_audit 2>&1)" "(watchdog leaking)"
printf '55 1000\n' >"$EAU/ctl/results/.egress-audit-prev"
eau_status egress_status >/dev/null
assert_eq "a leak that keeps rising keeps the time it was first seen" "$(eau_wd .host_audit.first_seen)" "1000"
out=$(eau_status egress_status)
assert_contains "a counter that stopped rising for a full interval clears" "$out" "watchdog=clean (rise 0"
assert_eq "and the first-seen time clears with it" "$(eau_wd .host_audit.first_seen)" "null"
cp "$EAU/json.base" "$EAU/json"
out=$(eau_status egress_status)
assert_contains "a counter that fell (the table was reloaded) is a new baseline, not a leak" "$out" "watchdog=clean"
assert_eq "and the lower count becomes the baseline" "$(cat "$EAU/ctl/results/.egress-audit-prev")" "55 - 0 0"
printf '08 0900\n' >"$EAU/ctl/results/.egress-audit-prev"
assert_contains "a zero-padded baseline is read as decimal, never as an octal error" \
    "$(eau_status egress_status)" "watchdog=leaking (rise 47 since the last check)"
assert_eq "and its zero-padded first-seen time stays valid JSON" "$(eau_wd .host_audit.first_seen)" "900"
eau_set 100 20 0
eau_status egress_status >/dev/null
eau_set 110 30 0
out=$(eau_status egress_status)
assert_contains "a rise only in allowlisted flows is allowlisted, never a leak" "$out" "watchdog=allowlisted (rise 0"
eau_set 120 30 10
assert_contains "a rise only in an operator's chosen clearnet path is operator-choice, never a leak" \
    "$(eau_status egress_status)" "watchdog=operator-choice (rise 0"
eau_set 140 34 10
assert_contains "a rise beyond the allowlisted and chosen flows is a leak, by the outside share only" \
    "$(eau_status egress_status)" "watchdog=leaking (rise 16 since the last check)"
assert_eq "the status file keeps the allowlisted, choice and outside counts" \
    "$(eau_wd '[.host_audit.allowlisted, .host_audit.choice, .host_audit.outside]')" '[34,10,96]'
EAU_NFT_TABLE_RC=1 eau_status egress_status >/dev/null
assert_eq "an absent audit table is not-observed, never clean" "$(eau_wd .host_audit.watchdog)" '"not-observed"'
SUDO_DENY=1 eau_status egress_status >/dev/null
assert_eq "an unreadable audit table is not-observed too" "$(eau_wd .host_audit.watchdog)" '"not-observed"'
