# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
: "${SANDBOX:?}"
: "${STACK:?}"

echo "== black-box: control power-reboot and power-shutdown (appliance only, host-side confirm) =="
PWC="$SANDBOX/power-control"
PWREQS="$PWC/data/control/requests"
PWRES="$PWC/data/control/results"
PWAUDIT="$PWC/data/control/audit/control.log"
PWOS="$PWC/osdir"
mkdir -p "$PWREQS" "$PWRES" "$PWC/data/control/staged" "$PWC/data/control/audit" "$PWOS"
cp "$STACK" "$PWC/pithead"
make_stubs "$PWC/bin"
printf '1.3.1' >"$PWC/VERSION"
printf '{}' >"$PWC/config.json"
cat >"$PWC/.env" <<EOT
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=true
CONTROL_DIR=$PWC/data/control
NETWORK_PREFIX=10.9.0
EOT
cat >"$PWC/bin/systemctl" <<'EOT'
#!/usr/bin/env bash
echo "[systemctl] $*" >>"${PW_ORDER_LOG:?}"
[ "${PW_SYSTEMCTL_FAIL:-}" != 1 ]
EOT
cat >"$PWC/bin/docker" <<'EOT'
#!/usr/bin/env bash
echo "[docker] $*" >>"${PW_ORDER_LOG:?}"
[ "${PW_STOP_FAIL:-}" != 1 ] || [ "$*" != "compose stop" ]
EOT
chmod +x "$PWC/bin/systemctl" "$PWC/bin/docker"
pwrun() { # [env pairs...] — drain the spool inside the appliance sandbox
    (cd "$PWC" && PATH="$PWC/bin:$PATH" PW_ORDER_LOG="$PWC/order.log" PITHEAD_APPLIANCE=1 \
        PITHEAD_OS_UPDATE_DIR="$PWOS" PITHEAD_RAUC_SYSTEM_CONF="$PWC/system.conf" \
        env "$@" ./pithead control-run-pending 2>&1)
}
pwintent() { # <id> <action> [confirm] — a well-formed request; no confirm key when omitted
    if [ "$#" -ge 3 ]; then
        printf '{"id":"%s","action":"%s","actor":"admin","confirm":"%s"}\n' "$1" "$2" "$3" >"$PWREQS/$1.json"
    else
        printf '{"id":"%s","action":"%s","actor":"admin"}\n' "$1" "$2" >"$PWREQS/$1.json"
    fi
}
pwstatus() { jq -r '.status' "$PWRES/$1.json" 2>/dev/null; }
pwerror() { jq -r '.error' "$PWRES/$1.json" 2>/dev/null; }
pwpower() { grep -c '^\[systemctl\]' "$PWC/order.log" || true; }
pwreset() { rm -f "$PWRES"/*.json "$PWC/data/control/power-cooldown" "$PWOS/in-flight.json" "$PWAUDIT"; : >"$PWC/order.log"; }
UP1="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
UP2="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
pwreset

pwintent "$UP1" power-reboot REBOOT
pwrun PITHEAD_APPLIANCE=0 >/dev/null
assert_eq "power-reboot off the appliance is rejected" "$(pwstatus "$UP1")" "rejected"
assert_contains "the DIY refusal uses the os-* wording" "$(pwerror "$UP1")" "Pithead OS appliance"
assert_eq "no power command off the appliance" "$(pwpower)" "0"
pwreset

for bad_confirm in "" "reboot" "SHUTDOWN"; do
    printf '{"id":"%s","action":"power-reboot","actor":"admin","confirm":"%s"}\n' "$UP1" "$bad_confirm" >"$PWREQS/$UP1.json"
    pwrun >/dev/null
    assert_eq "power-reboot with confirm '$bad_confirm' is rejected" "$(pwstatus "$UP1")" "rejected"
    assert_contains "the refusal names the word" "$(pwerror "$UP1")" "REBOOT"
    rm -f "$PWRES/$UP1.json"
done
pwintent "$UP1" power-reboot
pwrun >/dev/null
assert_eq "power-reboot without a confirm key is rejected" "$(pwstatus "$UP1")" "rejected"
pwintent "$UP1" power-shutdown REBOOT
pwrun >/dev/null
assert_eq "power-shutdown with the reboot word is rejected" "$(pwstatus "$UP1")" "rejected"
printf '{"id":"%s","action":"power-reboot","actor":"admin","confirm":"REBOOT","version":"1.0.0"}\n' "$UP1" >"$PWREQS/$UP1.json"
rm -f "$PWRES/$UP1.json"
pwrun >/dev/null
assert_eq "an extra request key is rejected" "$(pwstatus "$UP1")" "rejected"
assert_eq "no power command after a rejected word or shape" "$(pwpower)" "0"
assert_contains "the rejection is audited" "$(cat "$PWAUDIT")" '"action":"power-reboot","status":"rejected"'
assert_eq "no stack stop after a rejected word or shape" "$(grep -c 'compose stop' "$PWC/order.log" || true)" "0"
pwreset

pwintent "$UP1" power-reboot REBOOT
pwrun >/dev/null
assert_eq "power-reboot reports rebooting" "$(pwstatus "$UP1")" "rebooting"
assert_eq "the stack is stopped first, then systemctl reboot" "$(tr '\n' '|' <"$PWC/order.log")" "[docker] compose stop|[systemctl] reboot|"
assert_contains "the audit line carries the actor and action" "$(cat "$PWAUDIT")" '"actor":"admin","action":"power-reboot","status":"rebooting"'
pwreset

pwintent "$UP1" power-shutdown SHUTDOWN
pwrun >/dev/null
assert_eq "power-shutdown reports shutting-down" "$(pwstatus "$UP1")" "shutting-down"
assert_eq "the stack is stopped first, then systemctl poweroff" "$(tr '\n' '|' <"$PWC/order.log")" "[docker] compose stop|[systemctl] poweroff|"
assert_contains "the shutdown audit line is lowercase-dashed" "$(cat "$PWAUDIT")" '"action":"power-shutdown","status":"shutting-down"'
printf '{"id":"%s","action":"power-reboot","actor":"admin","confirm":"REBOOT"}\n' "$UP2" >"$PWREQS/$UP2.json"
pwrun >/dev/null
assert_eq "a second power verb inside the cooldown is rejected" "$(pwstatus "$UP2")" "rejected"
assert_contains "the cooldown refusal carries a retry hint" "$(pwerror "$UP2")" "retry"
assert_eq "the cooldown ordered no second power command" "$(pwpower)" "1"
printf '%s\n' "$(($(date +%s) - 400))" >"$PWC/data/control/power-cooldown"
rm -f "$PWRES/$UP1.json" "$PWRES/$UP2.json"
pwintent "$UP2" power-reboot REBOOT
pwrun >/dev/null
assert_eq "an expired cooldown lets the next verb run" "$(pwstatus "$UP2")" "rebooting"
pwreset

printf '{"step":"downloading"}\n' >"$PWRES/os-update-state.json"
pwintent "$UP1" power-reboot REBOOT
sleep 1
pwintent "$UP2" power-shutdown SHUTDOWN
pwrun >/dev/null
assert_contains "the first power verb in a drain gets its own verdict" "$(pwerror "$UP1")" "update"
assert_eq "the second power verb in the same drain is rejected" "$(pwstatus "$UP2")" "rejected"
assert_contains "the budget refusal says retry" "$(pwerror "$UP2")" "retry"
assert_contains "the budget refusal names a power step" "$(pwerror "$UP2")" "power step"
rm -f "$PWRES/os-update-state.json"
pwreset

for step in downloading installing verifying reboot-pending; do
    printf '{"step":"%s"}\n' "$step" >"$PWRES/os-update-state.json"
    pwintent "$UP1" power-shutdown SHUTDOWN
    pwrun >/dev/null
    assert_eq "power-shutdown while the OS update step is $step is rejected" "$(pwstatus "$UP1")" "rejected"
    assert_contains "the $step refusal names the update" "$(pwerror "$UP1")" "update"
    assert_eq "no power command while the OS update step is $step" "$(pwpower)" "0"
    rm -f "$PWRES/$UP1.json" "$PWC/data/control/power-cooldown"
done
printf '{"step":"idle"}\n' >"$PWRES/os-update-state.json"
pwintent "$UP1" power-reboot REBOOT
pwrun >/dev/null
assert_eq "an idle OS update state allows the verb" "$(pwstatus "$UP1")" "rebooting"
pwreset

printf '{"id":"%s","status":"rebooting","ts":1}\n' "cccccccc-cccc-4ccc-8ccc-cccccccccccc" >"$PWRES/cccccccc-cccc-4ccc-8ccc-cccccccccccc.json"
pwintent "$UP1" power-reboot REBOOT
pwrun >/dev/null
assert_eq "a reboot result already in flight rejects the verb" "$(pwstatus "$UP1")" "rejected"
assert_contains "the in-flight refusal says so" "$(pwerror "$UP1")" "in flight"
assert_eq "no power command with a result in flight" "$(pwpower)" "0"
pwreset

printf '{"checking":true,"id":"x","status":"checking","ts":1}\n' >"$PWRES/cccccccc-cccc-4ccc-8ccc-cccccccccccc.json"
pwintent "$UP1" power-shutdown SHUTDOWN
pwrun >/dev/null
assert_eq "an OS check in flight rejects the verb" "$(pwstatus "$UP1")" "rejected"
pwreset

printf '{"to":"1.3.1","ts":%s}\n' "$(date +%s)" >"$PWOS/in-flight.json"
printf '{"step":"idle"}\n' >"$PWRES/os-update-state.json"
pwintent "$UP1" power-reboot REBOOT
pwrun >/dev/null
assert_eq "the uncommitted-slot window rejects the verb" "$(pwstatus "$UP1")" "rejected"
assert_contains "the slot refusal explains the rollback" "$(pwerror "$UP1")" "previous version"
assert_eq "no power command in the uncommitted-slot window" "$(pwpower)" "0"
pwreset

printf '{"to":"9.9.9","ts":%s}\n' "$(date +%s)" >"$PWOS/in-flight.json"
printf '{"step":"idle"}\n' >"$PWRES/os-update-state.json"
pwintent "$UP1" power-reboot REBOOT
pwrun >/dev/null
assert_eq "an armed update for a different version does not block the verb" "$(pwstatus "$UP1")" "rebooting"
pwreset

(
    flock 9
    exec sleep 20
) 9>>"$PWC/.pithead.lock" &
PWHOLDER=$!
sleep 1
pwintent "$UP1" power-reboot REBOOT
pwrun >/dev/null
kill "$PWHOLDER" 2>/dev/null || true
wait "$PWHOLDER" 2>/dev/null || true
assert_eq "a held mutation lock rejects the verb" "$(pwstatus "$UP1")" "rejected"
assert_contains "the lock refusal says so" "$(pwerror "$UP1")" "lock"
assert_eq "no power command while the lock is held" "$(pwpower)" "0"
pwreset

pwintent "$UP1" power-reboot REBOOT
sleep 1
pwintent "$UP2" restart
pwrun >/dev/null
assert_eq "an ordered power command ends the drain" "$([ -f "$PWREQS/$UP2.json" ] && echo waiting || echo processed)" "waiting"
rm -f "$PWREQS/$UP2.json"
pwreset

printf '%s\n' "$(($(date +%s) + 86400))" >"$PWC/data/control/power-cooldown"
pwintent "$UP1" power-reboot REBOOT
pwrun >/dev/null
assert_eq "a cooldown stamp from the future does not lock the verb out" "$(pwstatus "$UP1")" "rebooting"
pwreset

printf '{"to":"9.9.9","ts":%s}\n' "$(date +%s)" >"$PWOS/in-flight.json"
printf 'not json' >"$PWRES/os-update-state.json"
pwintent "$UP1" power-reboot REBOOT
pwrun >/dev/null
assert_eq "an unreadable update state with an armed update rejects the verb" "$(pwstatus "$UP1")" "rejected"
assert_contains "the refusal names the unreadable state" "$(pwerror "$UP1")" "unreadable"
rm -f "$PWRES/os-update-state.json"
pwreset

pwintent "$UP1" power-reboot REBOOT
pwrun PW_SYSTEMCTL_FAIL=1 >/dev/null
assert_eq "a failed systemctl writes a failed result" "$(pwstatus "$UP1")" "failed"
assert_contains "the failed audit line is written" "$(cat "$PWAUDIT")" '"action":"power-reboot","status":"failed"'
pwreset

pwintent "$UP1" power-shutdown SHUTDOWN
pwrun PW_STOP_FAIL=1 >/dev/null
assert_eq "a stack that will not stop writes a failed result" "$(pwstatus "$UP1")" "failed"
assert_eq "no power command after a failed stack stop" "$(pwpower)" "0"

unset -f pwrun pwintent pwstatus pwerror pwpower pwreset
rm -rf "$PWC"
unset PWC PWREQS PWRES PWAUDIT PWOS UP1 UP2 PWHOLDER bad_confirm step
