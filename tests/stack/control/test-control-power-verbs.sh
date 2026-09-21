# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Plain power control verbs domain (#2384): sys-reboot / sys-poweroff, exercised through the
# control channel the way an operator reaches them. A release-shaped appliance sandbox — control
# channel on, PITHEAD_APPLIANCE forced, systemctl stubbed — proves off-appliance refusal, the
# control-channel-off gate, the result-before-order sequencing, both host-side bounds (the
# one-power-verb-per-drain budget and the per-verb cooldown across reboots, each asserted on its
# own refusal so a missing one cannot hide behind the other), and the unknown-action fallthrough,
# with no root and no real reboot.

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
case "$*" in
    reboot) power_status=rebooting power_action=sys-reboot ;;
    poweroff) power_status=shutting-down power_action=sys-poweroff ;;
esac
if jq -e --arg status "$power_status" '.status == $status' "${POWER_RESULT:?}" >/dev/null 2>&1 &&
    grep -Fq "\"action\":\"$power_action\",\"status\":\"$power_status\"" "${POWER_AUDIT:?}"; then
    echo "[systemctl-after-record] $*" >>"${SYSCTL_LOG:?}"
else
    echo "[systemctl-before-record] $*" >>"${SYSCTL_LOG:?}"
fi
exit 0
EOF
chmod +x "$PWC/bin/systemctl"
pwrun() { # [env pairs...] — drain the spool inside the appliance sandbox
    (cd "$PWC" && PATH="$PWC/bin:$PATH" SYSCTL_LOG="$PWC/sysctl.log" PITHEAD_APPLIANCE=1 \
        POWER_RESULT="$PWRES/$PW1.json" POWER_AUDIT="$PWC/data/control/audit/control.log" \
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
assert_eq "a refused verb claims no cooldown stamp" "$(find "$PWC/data/control" -maxdepth 1 -name '.power-stamp*' | wc -l | tr -d ' ')" "0"
rm -f "$PWRES/$PW1.json"

# With the control channel off, control_run_pending's own gate refuses the drain before any verb is
# reached: the request is left unclaimed, no result is written and nothing is ordered. The flag is
# read from .env by env_get, not from the environment, so the sandbox's file is what moves.
sed -i.bak 's/^DASHBOARD_CONTROL_ENABLED=true$/DASHBOARD_CONTROL_ENABLED=false/' "$PWC/.env"
pw_intent "$PW1" sys-reboot
pwrun >/dev/null 2>&1 && pw_off_rc=0 || pw_off_rc=$?
assert_rc "a drain with the control channel off fails" "$pw_off_rc" "1"
assert_eq "the power verb was never reached with the channel off" "$([ -f "$PWRES/$PW1.json" ] && echo answered || echo untouched)" "untouched"
assert_eq "nothing was ordered with the control channel off" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "0"
mv "$PWC/.env.bak" "$PWC/.env"
rm -f "$PWREQS/$PW1.json"

# On the appliance: the result lands BEFORE the order, and the order is the right one for the verb.
pw_intent "$PW1" sys-reboot
pwrun >/dev/null
assert_eq "sys-reboot reports rebooting" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rebooting"
assert_contains "systemctl reboot was ordered" "$(cat "$PWC/sysctl.log")" "reboot"
assert_contains "the reboot order follows its result and audit" "$(cat "$PWC/sysctl.log")" "systemctl-after-record"
assert_not_contains "the reboot order never precedes its record" "$(cat "$PWC/sysctl.log")" "systemctl-before-record"
assert_not_contains "sys-reboot never orders poweroff" "$(cat "$PWC/sysctl.log")" "poweroff"
# The audit line carries id/actor/action, written alongside the result.
assert_contains "the audit line names sys-reboot" "$(tail -1 "$PWC/data/control/audit/control.log")" "\"action\":\"sys-reboot\""
# The cooldown stamp is claimed in the OWNER-ONLY control parent, never in the container-writable
# requests spool — an asker that could clear its own cooldown would not have one.
assert_eq "the accepted order claimed its cooldown stamp outside the spool" \
    "$([ -f "$PWC/data/control/.power-stamp.sys-reboot" ] && echo claimed || echo missing)" "claimed"
assert_eq "the stamp is not in the container-writable spool" "$(find "$PWREQS" -name '.power-stamp*' | wc -l | tr -d ' ')" "0"
rm -f "$PWRES/$PW1.json"
: >"$PWC/sysctl.log"

# A second sys-reboot in a FRESH drain is refused by the cooldown: the per-drain budget bounds
# concurrency, and only this bounds the rate — an unbounded reboot loop is a box nobody can reach.
pw_intent "$PW1" sys-reboot
pwrun >/dev/null
assert_eq "a second sys-reboot inside the cooldown is rejected" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rejected"
assert_contains "the cooldown refusal names the window" "$(jq -r '.error' "$PWRES/$PW1.json" 2>/dev/null)" "less than five minutes ago"
assert_eq "the cooled-down reboot ordered nothing" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "0"
rm -f "$PWRES/$PW1.json"
# ...and the cooldown is a WINDOW, not a one-shot lock: an aged stamp lets the next order through.
touch -t 202001010000 "$PWC/data/control/.power-stamp.sys-reboot"
pw_intent "$PW1" sys-reboot
pwrun >/dev/null
assert_eq "an aged cooldown lets the next reboot through" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rebooting"
assert_eq "and that one ordered exactly one reboot" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "1"
rm -f "$PWRES/$PW1.json"
: >"$PWC/sysctl.log"

# A poweroff straight after a reboot is the operator's real sequence (reboot, see it did not help,
# power off to go and move the box), so the cooldown is per verb and must NOT refuse it.
pw_intent "$PW1" sys-poweroff
pwrun >/dev/null
assert_eq "sys-poweroff reports shutting-down" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "shutting-down"
assert_contains "systemctl poweroff was ordered" "$(cat "$PWC/sysctl.log")" "poweroff"
assert_contains "the poweroff order follows its result and audit" "$(cat "$PWC/sysctl.log")" "systemctl-after-record"
assert_not_contains "the poweroff order never precedes its record" "$(cat "$PWC/sysctl.log")" "systemctl-before-record"
assert_not_contains "sys-poweroff never orders reboot" "$(cat "$PWC/sysctl.log")" "systemctl] reboot"
assert_contains "the audit line names sys-poweroff" "$(tail -1 "$PWC/data/control/audit/control.log")" "\"action\":\"sys-poweroff\""
rm -f "$PWRES/$PW1.json"
: >"$PWC/sysctl.log"

# One power verb per drain: a second one in the same cycle rejects with a retry hint, and no
# second order is ever issued.
touch -t 202001010000 "$PWC/data/control/.power-stamp.sys-reboot" # the BUDGET is what must refuse here
pw_intent "$PW1" sys-reboot
sleep 1 # distinct mtimes so the drain order is deterministic (oldest first)
pw_intent "$PW2" sys-poweroff
pwrun >/dev/null
assert_eq "the first power verb in a drain runs" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rebooting"
assert_eq "the second power verb in the same drain is rejected" "$(jq -r '.status' "$PWRES/$PW2.json" 2>/dev/null)" "rejected"
# The exact refusal, not just the word "retry": the budget and the cooldown are two different
# bounds and a test that cannot tell them apart would pass with either one missing.
assert_contains "the budget refusal names the cycle, not the cooldown" "$(jq -r '.error' "$PWRES/$PW2.json" 2>/dev/null)" "already running in this cycle"
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

# The action set now lives in TWO places — the host dispatch `case` (49-control-request-loop.sh) and
# the route's Python frozenset (power_views.py) — so pin them against each other, in BOTH
# directions: a verb added host-side only is unreachable behind a route that can never ask for it,
# and a verb added route-side only 400s at the door. This guard lives here rather than in the
# dashboard's own pytest suite because that suite runs inside the dashboard image, whose test stage
# copies only dashboard/ — lib/pithead/ is absent there, and a guard that has to be skipped when
# its input is missing is how a required check quietly stops checking.
PW_HOST_ACTIONS=$(sed -n 's/^[[:space:]]*sys-\([a-z-]*\)).*/\1/p' "$ROOT/lib/pithead/49-control-request-loop.sh" | sort | tr '\n' ' ')
PW_ROUTE_ACTIONS=$(sed -n 's/^POWER_ACTIONS = frozenset({\(.*\)})$/\1/p' "$ROOT/dashboard/mining_dashboard/web/views/power_views.py" |
    tr -d '"' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep . | sort | tr '\n' ' ')
assert_eq "the host case names the two power verbs" "$PW_HOST_ACTIONS" "poweroff reboot "
assert_eq "the route's frozenset matches the host case exactly, both ways" "$PW_ROUTE_ACTIONS" "$PW_HOST_ACTIONS"

unset -f pwrun pw_intent
rm -rf "$PWC"
unset PWC PWREQS PWRES PW1 PW2 pw_off_rc PW_HOST_ACTIONS PW_ROUTE_ACTIONS
