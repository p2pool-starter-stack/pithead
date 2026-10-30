# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

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
cat >"$PWC/bin/touch" <<'EOF'
#!/usr/bin/env bash
if [ "${PITHEAD_FAIL_POWER_STAMP:-}" = 1 ] && [[ "$*" == *".power-stamp."* ]]; then
    exit 1
fi
exec /usr/bin/touch "$@"
EOF
chmod +x "$PWC/bin/systemctl" "$PWC/bin/touch"
cat >"$PWC/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [ "${PITHEAD_FAIL_POWER_RESULT:-}" = 1 ] && [[ "$*" == *"results/"* ]]; then
    exit 1
fi
exec /bin/mv "$@"
EOF
chmod +x "$PWC/bin/mv"
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

sed -i.bak 's/^DASHBOARD_CONTROL_ENABLED=true$/DASHBOARD_CONTROL_ENABLED=false/' "$PWC/.env"
pw_intent "$PW1" sys-reboot
pwrun >/dev/null 2>&1 && pw_off_rc=0 || pw_off_rc=$?
assert_rc "a drain with the control channel off fails" "$pw_off_rc" "1"
assert_eq "the power verb was never reached with the channel off" "$([ -f "$PWRES/$PW1.json" ] && echo answered || echo untouched)" "untouched"
assert_eq "nothing was ordered with the control channel off" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "0"
mv "$PWC/.env.bak" "$PWC/.env"
rm -f "$PWREQS/$PW1.json"

pw_intent "$PW1" sys-reboot
pwrun PITHEAD_FAIL_POWER_STAMP=1 >/dev/null
assert_eq "a missing cooldown stamp rejects the order" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rejected"
assert_contains "the stamp refusal says nothing changed" "$(jq -r '.error' "$PWRES/$PW1.json" 2>/dev/null)" "nothing was changed"
assert_eq "a missing cooldown stamp orders nothing" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "0"
rm -f "$PWRES/$PW1.json"

pw_intent "$PW1" sys-reboot
pwrun PITHEAD_FAIL_POWER_RESULT=1 >/dev/null 2>&1
assert_eq "a failed result write orders nothing" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "0"
rm -f "$PWC/data/control/.power-stamp.sys-reboot" "$PWC/data/control/audit/control.log"
mkdir "$PWC/data/control/audit/control.log"
pw_intent "$PW1" sys-reboot
pwrun >/dev/null 2>&1
assert_eq "a failed audit write orders nothing" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "0"
rmdir "$PWC/data/control/audit/control.log"
rm -f "$PWRES/$PW1.json" "$PWC/data/control/.power-stamp.sys-reboot"

pw_intent "$PW1" sys-reboot
pwrun >/dev/null
assert_eq "sys-reboot reports rebooting" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rebooting"
assert_contains "systemctl reboot was ordered" "$(cat "$PWC/sysctl.log")" "reboot"
assert_contains "the reboot order follows its result and audit" "$(cat "$PWC/sysctl.log")" "systemctl-after-record"
assert_not_contains "the reboot order never precedes its record" "$(cat "$PWC/sysctl.log")" "systemctl-before-record"
assert_not_contains "sys-reboot never orders poweroff" "$(cat "$PWC/sysctl.log")" "poweroff"
assert_contains "the audit line names sys-reboot" "$(tail -1 "$PWC/data/control/audit/control.log")" "\"action\":\"sys-reboot\""
assert_eq "the accepted order claimed its cooldown stamp outside the spool" \
    "$([ -f "$PWC/data/control/.power-stamp.sys-reboot" ] && echo claimed || echo missing)" "claimed"
assert_eq "the stamp is not in the container-writable spool" "$(find "$PWREQS" -name '.power-stamp*' | wc -l | tr -d ' ')" "0"
rm -f "$PWRES/$PW1.json"
: >"$PWC/sysctl.log"

pw_intent "$PW1" sys-reboot
pwrun >/dev/null
assert_eq "a second sys-reboot inside the cooldown is rejected" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rejected"
assert_contains "the cooldown refusal names the window" "$(jq -r '.error' "$PWRES/$PW1.json" 2>/dev/null)" "less than five minutes ago"
assert_eq "the cooled-down reboot ordered nothing" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "0"
rm -f "$PWRES/$PW1.json"
touch -t 202001010000 "$PWC/data/control/.power-stamp.sys-reboot"
pw_intent "$PW1" sys-reboot
pwrun >/dev/null
assert_eq "an aged cooldown lets the next reboot through" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rebooting"
assert_eq "and that one ordered exactly one reboot" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "1"
rm -f "$PWRES/$PW1.json"
: >"$PWC/sysctl.log"

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

touch -t 202001010000 "$PWC/data/control/.power-stamp.sys-reboot" # the BUDGET is what must refuse here
pw_intent "$PW1" sys-reboot
sleep 1 # distinct mtimes so the drain order is deterministic (oldest first)
pw_intent "$PW2" sys-poweroff
pwrun >/dev/null
assert_eq "the first power verb in a drain runs" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rebooting"
assert_eq "the second power verb in the same drain is rejected" "$(jq -r '.status' "$PWRES/$PW2.json" 2>/dev/null)" "rejected"
assert_contains "the budget refusal names the cycle, not the cooldown" "$(jq -r '.error' "$PWRES/$PW2.json" 2>/dev/null)" "already running in this cycle"
assert_eq "only one order was issued for the whole drain" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "1"
rm -f "$PWRES/$PW1.json" "$PWRES/$PW2.json"
: >"$PWC/sysctl.log"

pw_intent "$PW1" sys-flambe
pwrun >/dev/null
assert_eq "an unknown power-shaped action is rejected" "$(jq -r '.status' "$PWRES/$PW1.json" 2>/dev/null)" "rejected"
assert_contains "the unknown-action refusal names it" "$(jq -r '.error' "$PWRES/$PW1.json" 2>/dev/null)" "unknown action"
assert_eq "no order was issued for an unknown action" "$(wc -l <"$PWC/sysctl.log" | tr -d ' ')" "0"
rm -f "$PWRES/$PW1.json"

PW_HOST_ACTIONS=$(sed -n 's/^[[:space:]]*sys-\([a-z-]*\)).*/\1/p' "$ROOT/lib/pithead/49-control-request-loop.sh" | sort | tr '\n' ' ')
PW_ROUTE_ACTIONS=$(sed -n 's/^POWER_ACTIONS = frozenset({\(.*\)})$/\1/p' "$ROOT/dashboard/mining_dashboard/web/views/power_views.py" |
    tr -d '"' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep . | sort | tr '\n' ' ')
assert_eq "the host case names the two power verbs" "$PW_HOST_ACTIONS" "poweroff reboot "
assert_eq "the route's frozenset matches the host case exactly, both ways" "$PW_ROUTE_ACTIONS" "$PW_HOST_ACTIONS"

unset -f pwrun pw_intent
rm -rf "$PWC"
unset PWC PWREQS PWRES PW1 PW2 pw_off_rc PW_HOST_ACTIONS PW_ROUTE_ACTIONS
