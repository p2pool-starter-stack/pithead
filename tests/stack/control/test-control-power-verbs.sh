# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Plain power control verbs domain (#2384): sys-reboot / sys-poweroff, exercised through the
# control channel the way an operator reaches them. A release-shaped appliance sandbox — control
# channel on, PITHEAD_APPLIANCE forced, systemctl stubbed — proves off-appliance refusal, the
# result-before-order sequencing, the one-power-verb-per-drain budget, and the unknown-action
# fallthrough, with no root and no real reboot.

echo "== black-box: control power verbs (sys-reboot / sys-poweroff, dashboard-driven) =="
PWC="$SANDBOX/power-control"
PWREQS="$PWC/data/control/requests"
PWRES="$PWC/data/control/results"
mkdir -p "$PWREQS" "$PWC/data/control/staged" "$PWRES" "$PWC/data/control/audit" "$PWC/bin"
cp "$STACK" "$PWC/pithead"
printf '1.3.1' >"$PWC/VERSION"
printf '{}' >"$PWC/config.json"
cat >"$PWC/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=true
CONTROL_DIR=$PWC/data/control
EOF
cat >"$PWC/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "[systemctl] $*" >>"${SYSCTL_LOG:?}"
exit 0
EOF
chmod +x "$PWC/bin/systemctl"
pwrun() { # [env pairs...] — drain the spool inside the appliance sandbox
    (cd "$PWC" && PATH="$PWC/bin:$PATH" SYSCTL_LOG="$PWC/sysctl.log" PITHEAD_APPLIANCE=1 \
        env "$@" ./pithead control-run-pending 2>&1)
}
pw_intent() { # <id> <action>
    printf '{"id":"%s","action":"%s","actor":"admin"}\n' "$1" "$2" >"$PWREQS/$1.json"
}
PW1="66666666-6666-4666-8666-666666666666"
PW2="55555555-5555-4555-8555-555555555555"
: >"$PWC/sysctl.log"

# Off the appliance both verbs refuse outright, and NOTHING is ordered.
pw_intent "$PW1" sys-reboot
pwrun PITHEAD_APPLIANCE=0 >/dev/null
assert_eq "sys-reboot off the appliance is rejected" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names the appliance" "$(jq -r '.error' "$PWRES/$PW1.json" 2>/dev/null)" "appliance"
assert_eq "no order was issued off the appliance" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "0"
rm -f "$PWRES/$PW1.json"

pw_intent "$PW1" sys-poweroff
pwrun PITHEAD_APPLIANCE=0 >/dev/null
assert_eq "sys-poweroff off the appliance is rejected" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rejected"
assert_eq "no order was issued off the appliance" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "0"
rm -f "$PWRES/$PW1.json"

# On the appliance: the result lands BEFORE the order, and the order is the right one for the verb.
pw_intent "$PW1" sys-reboot
pwrun >/dev/null
assert_eq "sys-reboot reports rebooting" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rebooting"
assert_contains "systemctl reboot was ordered" "$(cat "$PWC/sysctl.log")" "reboot"
assert_not_contains "sys-reboot never orders poweroff" "$(cat "$PWC/sysctl.log")" "poweroff"
# The audit line carries id/actor/action, written alongside the result.
assert_contains "the audit line names sys-reboot" "$(tail -1 "$PWC/data/control/audit/control.log")" "\"action\":\"sys-reboot\""
rm -f "$PWRES/$PW1.json"
: >"$PWC/sysctl.log"

pw_intent "$PW1" sys-poweroff
pwrun >/dev/null
assert_eq "sys-poweroff reports shutting-down" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "shutting-down"
assert_contains "systemctl poweroff was ordered" "$(cat "$PWC/sysctl.log")" "poweroff"
assert_not_contains "sys-poweroff never orders reboot" "$(cat "$PWC/sysctl.log")" "systemctl] reboot"
assert_contains "the audit line names sys-poweroff" "$(tail -1 "$PWC/data/control/audit/control.log")" "\"action\":\"sys-poweroff\""
rm -f "$PWRES/$PW1.json"
: >"$PWC/sysctl.log"

# One power verb per drain: a second one in the same cycle rejects with a retry hint, and no
# second order is ever issued.
pw_intent "$PW1" sys-reboot
sleep 1 # distinct mtimes so the drain order is deterministic (oldest first)
pw_intent "$PW2" sys-poweroff
pwrun >/dev/null
assert_eq "the first power verb in a drain runs" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rebooting"
assert_eq "the second power verb in the same drain is rejected" "$(jq -r '.status' "$PWRES/$PW2.json" 2>/dev/null)" "rejected"
assert_contains "the budget refusal says retry" "$(jq -r '.error' "$PWRES/$PW2.json" 2>/dev/null)" "retry"
assert_eq "only one order was issued for the whole drain" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "1"
rm -f "$PWRES/$PW1.json" "$PWRES/$PW2.json"
: >"$PWC/sysctl.log"

# A malformed/unknown action still falls through to the case's unknown-action branch, unchanged.
pw_intent "$PW1" sys-flambe
pwrun >/dev/null
assert_eq "an unknown power-shaped action is rejected" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rejected"
assert_contains "the unknown-action refusal names it" "$(jq -r '.error' "$PWRES/$PW1.json" 2>/dev/null)" "unknown action"
assert_eq "no order was issued for an unknown action" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "0"
rm -f "$PWRES/$PW1.json"

unset -f pwrun pw_intent
rm -rf "$PWC"
unset PWC PWREQS PWRES PW1 PW2
