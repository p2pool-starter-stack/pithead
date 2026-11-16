# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-channel lifecycle-verb domain (#1105 Phase 1, appliance lane): the #33 runner's BOUNDED
# action set. The runner dispatches each accepted verb to a FIXED pithead command and audits it; an
# unknown verb is rejected, and no host command runs on the rejection path.
#
# Sourced by tests/stack/run.sh.
#
# This domain IS standalone-sourceable once tests/stack/lib.sh has been sourced, and it needs
# nothing from any sibling domain file. It is not a consumer of the shared control sandbox: it
# never calls build_control_sandbox(), and it never reads $C, $CTRL_LOG or the request-spool
# globals. It builds its own control directory under $SANDBOX instead. So the add-only-ssrf
# disclosure precedent that governs the pure-consumer control domains does not apply here, and
# neither does the position lock that comes with it: this domain reads no state a sibling leaves
# behind, writes nothing outside its own directory under $SANDBOX, and unsets the environment it
# exports before it ends. Both directions were checked, and both are re-derivable with grep here.
#
# Re-derivations, audited over this WHOLE file, this header included. The audit script is
# lane-local and is NOT in this repo, so nothing below rests on it: each claim is written to be
# re-derived here with git and grep alone, and should be treated as a claim to check.
# - $SANDBOX is the ONLY name this file reads without assigning. It is a lib.sh top-level constant,
#   assigned at column 1 rather than inside a function — the distinction that matters, because a
#   name a provider assigns only inside a function reaches a domain file as an ordering dependency
#   and not as a constant. The guard below states that single requirement explicitly.
# - $CC is assigned here, in the moved text, not inherited.
# - The lib.sh helpers this domain calls (assert_contains, assert_eq, run_sourced_e) are likewise
#   defined at lib.sh's top level.

: "${SANDBOX:?}"

echo "== control channel: bounded lifecycle verbs (#338 dispatch table, #2076) =="
# The #33 runner dispatches the two bounded lifecycle verbs to FIXED pithead commands and audits
# them; an unknown verb is rejected and no host command runs. PITHEAD_SELF points the runner at a
# stub that only records the literal verb it was handed, so nothing real is applied/restarted.
CC="$SANDBOX/ctrl338"
mkdir -p "$CC/staged" "$CC/results" "$CC/audit"
cat >"$CC/self" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SELF_LOG"
[ "${SELF_RC:-0}" -eq 0 ] || echo "$*" >&2
exit "${SELF_RC:-0}"
EOF
chmod +x "$CC/self"
export SELF_LOG="$CC/self.log"
export PITHEAD_SELF="$CC/self"
uid_r="11111111-1111-4111-8111-111111111111"
uid_a="22222222-2222-4222-8222-222222222222"
uid_x="33333333-3333-4333-8333-333333333333"
uid_f="44444444-4444-4444-8444-444444444444"

: >"$SELF_LOG"
printf '{"id":"%s","action":"restart","actor":"tester"}\n' "$uid_r" >"$CC/req_r.json"
run_sourced_e "$SANDBOX" control_process_request "$CC/req_r.json" "$CC" >/dev/null 2>&1
assert_eq "restart intent runs the fixed 'restart' verb" "$(cat "$SELF_LOG")" "restart"
assert_eq "restart result is applied" "$(jq -r .status "$CC/results/$uid_r.json")" "applied"
assert_contains "restart is audited with the actor + action" \
    "$(cat "$CC/audit/control.log")" '"actor":"tester","action":"restart","status":"applied"'

: >"$SELF_LOG"
printf '{"id":"%s","action":"apply","actor":"tester"}\n' "$uid_a" >"$CC/req_a.json"
run_sourced_e "$SANDBOX" control_process_request "$CC/req_a.json" "$CC" >/dev/null 2>&1
assert_eq "apply intent runs the fixed 'apply -y' verb (config re-apply, no edit)" "$(cat "$SELF_LOG")" "apply -y"
assert_eq "apply result is applied" "$(jq -r .status "$CC/results/$uid_a.json")" "applied"

export SELF_RC=1
printf '{"id":"%s","action":"apply","actor":"tester"}\n' "$uid_f" >"$CC/req_f.json"
run_sourced "$SANDBOX" control_process_request "$CC/req_f.json" "$CC" >/dev/null 2>&1
assert_contains "failed lifecycle result carries the child log separately" "$(jq -r .log "$CC/results/$uid_f.json")" "apply -y"
unset SELF_RC

: >"$SELF_LOG"
printf '{"id":"%s","action":"frobnicate","actor":"tester"}\n' "$uid_x" >"$CC/req_x.json"
run_sourced_e "$SANDBOX" control_process_request "$CC/req_x.json" "$CC" >/dev/null 2>&1
assert_eq "unknown verb rejected (bounded action set)" "$(jq -r .error "$CC/results/$uid_x.json")" "unknown action"
assert_eq "unknown verb never runs a host command" "$(cat "$SELF_LOG")" ""

echo "== control channel: restart refusals (#4064) =="
uid_n="55555555-5555-4555-8555-555555555555"
printf '{"id":"%s","action":"restart","actor":"tester"}\n' "$uid_n" >"$CC/req_n.json"
restart_refusal_case() { # <label> <substring of the reason>; the caller sets up the state
    : >"$SELF_LOG"
    rm -f "$CC/results/$uid_n.json" "$CC/audit/control.log"
    cp "$CC/req_n.json" "$CC/req_n.run.json"
    run_sourced_e "$SANDBOX" control_process_request "$CC/req_n.run.json" "$CC" >/dev/null 2>&1
    assert_eq "$1: rejected" "$(jq -r .status "$CC/results/$uid_n.json")" "rejected"
    assert_contains "$1: the reason reaches the result" "$(jq -r .error "$CC/results/$uid_n.json")" "$2"
    assert_eq "$1: the host restart never runs" "$(cat "$SELF_LOG")" ""
    assert_contains "$1: audited as rejected with the actor" \
        "$(cat "$CC/audit/control.log")" '"actor":"tester","action":"restart","status":"rejected"'
}
for step in downloading installing verifying reboot-pending; do
    rm -f "$CC/restart-at"
    printf '{"step":"%s","version":"v9.9.9"}\n' "$step" >"$CC/results/os-update-state.json"
    restart_refusal_case "restart during OS update step $step" "OS update is in progress ($step)"
done
printf '{"step":"idle"}\n' >"$CC/results/os-update-state.json"
mkdir -p "$CC/os"
printf '{"to":"9.9.9"}\n' >"$CC/os/in-flight.json"
export PITHEAD_OS_UPDATE_DIR="$CC/os" PITHEAD_VERSION="9.9.9"
rm -f "$CC/restart-at"
restart_refusal_case "restart in the uncommitted-slot window" "still being committed"
unset PITHEAD_OS_UPDATE_DIR PITHEAD_VERSION
rm -f "$CC/results/os-update-state.json"
date +%s >"$CC/restart-at"
restart_refusal_case "a second restart inside the cooldown" "already requested"
rm -f "$CC/restart-at"
: >"$SELF_LOG"
export SELF_RC=75
printf '{"id":"%s","action":"restart","actor":"tester"}\n' "$uid_n" >"$CC/req_n.run.json"
rm -f "$CC/results/$uid_n.json"
run_sourced_e "$SANDBOX" control_process_request "$CC/req_n.run.json" "$CC" >/dev/null 2>&1
assert_eq "a lock taken after the probe is a rejected busy restart, not a failure" \
    "$(jq -r .status "$CC/results/$uid_n.json")" "rejected"
assert_contains "the late busy reason says nothing was restarted" \
    "$(jq -r .error "$CC/results/$uid_n.json")" "took the lock first"
assert_eq "a late-lock rejection does not use up the restart cooldown" \
    "$([ -e "$CC/restart-at" ] && echo present || echo absent)" "absent"
unset SELF_RC
rm -f "$CC/restart-at"
: >"$SELF_LOG"
rm -f "$CC/results/$uid_n.json"
cp "$CC/req_n.json" "$CC/req_n.run.json"
bash -Eeuo pipefail -c 'cd "$1"; source "$2"; mutation_lock_acquire() { return 1; }; control_process_request "$3" "$4"' \
    _ "$SANDBOX" "$STACK" "$CC/req_n.run.json" "$CC" >/dev/null 2>&1
assert_eq "restart while a host operation holds the lock: rejected, not queued" \
    "$(jq -r .status "$CC/results/$uid_n.json")" "rejected"
assert_contains "the busy reason names the running operations" \
    "$(jq -r .error "$CC/results/$uid_n.json")" "another host operation"
assert_eq "a busy restart never runs the host restart" "$(cat "$SELF_LOG")" ""
: >"$SELF_LOG"
printf '{"id":"%s","action":"apply","actor":"tester"}\n' "$uid_a" >"$CC/req_a.json"
printf '{"step":"installing"}\n' >"$CC/results/os-update-state.json"
run_sourced_e "$SANDBOX" control_process_request "$CC/req_a.json" "$CC" >/dev/null 2>&1
assert_eq "an OS-update step does not refuse apply" "$(cat "$SELF_LOG")" "apply -y"
rm -f "$CC/results/os-update-state.json"
unset PITHEAD_SELF SELF_LOG

echo "== control channel: svc-restart — one allowlisted service, under the lock, with a cooldown (#4062) =="
SR="$SANDBOX/ctrl4062"
mkdir -p "$SR/results" "$SR/audit" "$SR/bin"
cat >"$SR/bin/docker" <<'EOF2'
#!/usr/bin/env bash
if [ "$1" = inspect ]; then
    case "$2" in
    tor) echo "${SR_TOR_HEALTH-healthy}" ;;
    monerod) echo true ;;
    esac
    exit 0
fi
echo "$*" >>"$SR_DOCKER_LOG"
[ "${SR_DOCKER_RC:-0}" -eq 0 ] || { echo "no such service" >&2; exit "$SR_DOCKER_RC"; }
exit 0
EOF2
chmod +x "$SR/bin/docker"
export SR SR_DOCKER_LOG="$SR/docker.log"
sr_req() {
    printf '{"id":"%s","action":"svc-restart","actor":"admin"%s%s}\n' "$1" "${2:+,\"container\":$2}" "${3:-}" >"$SR/req-$1.json"
    printf '%s\n' "$SR/req-$1.json"
}
sr_run() {
    (
        export PATH="$SR/bin:$PATH" PITHEAD_LOCK_FILE="$SR/.lock"
        if [ "${2:-1}" = 0 ]; then
            bash -Eeuo pipefail -c 'cd "$1"; source "$2"; lan_guard_ready() { return 1; }; control_process_request "$3" "$4"' _ "$SANDBOX" "$STACK" "$1" "$SR"
        else
            run_sourced_e "$SANDBOX" control_process_request "$1" "$SR"
        fi
    ) >/dev/null 2>&1
}
sr_status() { jq -r '.status' "$SR/results/$1.json"; }
sr_id() { printf 'c4062c40-0000-4000-8000-%012d' "$1"; }

: >"$SR_DOCKER_LOG"
sr_run "$(sr_req "$(sr_id 1)" '"tor"')"
assert_eq "an allowlisted service restarts" "$(sr_status "$(sr_id 1)")" "applied"
assert_eq "a tor restart re-dials monerod after Tor reports bootstrapped (#4063)" "$(cat "$SR_DOCKER_LOG")" \
    $'compose restart tor\ncompose restart monerod'
assert_contains "started and applied are audited with the actor and the service" \
    "$(cat "$SR/audit/control.log")" '"actor":"admin","action":"svc-restart","status":"applied","keys":"tor"'
assert_contains "the audit also records the start" "$(cat "$SR/audit/control.log")" '"action":"svc-restart","status":"started","keys":"tor"'

: >"$SR_DOCKER_LOG"
sr_run "$(sr_req "$(sr_id 2)" '"tor"')"
assert_eq "a repeat inside the cooldown is rejected" "$(sr_status "$(sr_id 2)")" "rejected"
assert_contains "the cooldown refusal says why" "$(jq -r .error "$SR/results/$(sr_id 2).json")" "wait before restarting it again"
assert_eq "a cooled-down request never reaches docker" "$(cat "$SR_DOCKER_LOG")" ""

: >"$SR_DOCKER_LOG"
sr_run "$(sr_req "$(sr_id 3)" '"monerod"')"
assert_eq "the cooldown is per service" "$(sr_status "$(sr_id 3)")" "applied"
printf '%s\n' "$(($(date +%s) - 1000))" >"$SR/svc-restart-tor"
sr_run "$(sr_req "$(sr_id 4)" '"tor"')"
assert_eq "an expired cooldown allows the restart again" "$(sr_status "$(sr_id 4)")" "applied"

: >"$SR_DOCKER_LOG"
rm -f "$SR/svc-restart-tor"
SR_TOR_HEALTH=starting PITHEAD_TOR_REDIAL_POLLS=1 PITHEAD_TOR_REDIAL_POLL_S=0 sr_run "$(sr_req "$(sr_id 5)" '"tor"')"
assert_eq "a tor restart whose Tor never bootstraps is a failed result (#4063)" "$(sr_status "$(sr_id 5)")" "failed"
assert_contains "the failure says monerod was not re-dialled" "$(jq -r .error "$SR/results/$(sr_id 5).json")" "Restart monerod once Tor is healthy"
assert_eq "monerod is not restarted before Tor bootstraps" "$(cat "$SR_DOCKER_LOG")" "compose restart tor"
assert_contains "the re-dial failure is audited" "$(cat "$SR/audit/control.log")" '"action":"svc-restart","status":"failed","keys":"tor"'

sr_allowed=""
for svc in wallet-rpc tari tari-wallet p2pool xmrig-proxy; do
    : >"$SR_DOCKER_LOG"
    sr_run "$(sr_req "$(sr_id 10)" "\"$svc\"")"
    sr_allowed+="$(cat "$SR_DOCKER_LOG")"$'\n'
    rm -f "$SR/results/$(sr_id 10).json"
done
assert_eq "every other allowlisted service restarts with exactly one compose restart" "$sr_allowed" \
    $'compose restart wallet-rpc\ncompose restart tari\ncompose restart tari-wallet\ncompose restart p2pool\ncompose restart xmrig-proxy\n'

sr_audit="$(cat "$SR/audit/control.log")"
assert_contains "the audit records wallet-rpc with its hyphen" "$sr_audit" '"action":"svc-restart","status":"applied","keys":"wallet-rpc"'
assert_contains "the audit records tari-wallet with its hyphen" "$sr_audit" '"action":"svc-restart","status":"applied","keys":"tari-wallet"'
assert_contains "the audit records xmrig-proxy with its hyphen" "$sr_audit" '"action":"svc-restart","status":"applied","keys":"xmrig-proxy"'

sr_refused=""
: >"$SR_DOCKER_LOG"
for bad_svc in dashboard caddy docker-proxy docker-control "tor monerod" "tor;id" '' '../tor' 'TOR' 'torx'; do
    sr_run "$(sr_req "$(sr_id 20)" "\"$bad_svc\"")"
    sr_refused+="$(sr_status "$(sr_id 20)") "
    rm -f "$SR/results/$(sr_id 20).json"
done
assert_eq "every non-allowlisted name is rejected by exact membership" "$sr_refused" \
    "rejected rejected rejected rejected rejected rejected rejected rejected rejected rejected "
assert_eq "no rejected name ever reaches docker" "$(cat "$SR_DOCKER_LOG")" ""
sr_run "$(sr_req "$(sr_id 21)" '')"
assert_eq "a request with no service is rejected" "$(sr_status "$(sr_id 21)")" "rejected"
sr_run "$(sr_req "$(sr_id 22)" '7')"
assert_eq "a non-string service is rejected" "$(sr_status "$(sr_id 22)")" "rejected"
sr_run "$(sr_req "$(sr_id 23)" '["tor"]')"
assert_eq "an array service is rejected" "$(sr_status "$(sr_id 23)")" "rejected"
sr_run "$(sr_req "$(sr_id 24)" '"p2pool"' ',"lines":5')"
assert_eq "extra keys on the verb are rejected and nothing restarts" "$(sr_status "$(sr_id 24)")" "rejected"
assert_contains "a rejection is audited" "$(cat "$SR/audit/control.log")" '"action":"svc-restart","status":"rejected"'

: >"$SR_DOCKER_LOG"
rm -f "$SR/svc-restart-p2pool"
sr_run "$(sr_req "$(sr_id 30)" '"p2pool"')" 0
assert_eq "a restart is refused while the LAN guard is not ready" "$(sr_status "$(sr_id 30)")" "rejected"
assert_contains "the guard refusal names the cause" "$(jq -r .error "$SR/results/$(sr_id 30).json")" "LAN-only source rule"
assert_eq "a guard refusal never reaches docker" "$(cat "$SR_DOCKER_LOG")" ""

: >"$SR_DOCKER_LOG"
SR_DOCKER_RC=1 sr_run "$(sr_req "$(sr_id 31)" '"p2pool"')"
assert_eq "a failing compose restart is a failed result" "$(sr_status "$(sr_id 31)")" "failed"
assert_contains "the failure carries the host's reason" "$(jq -r .error "$SR/results/$(sr_id 31).json")" "no such service"
assert_contains "the failure is audited" "$(cat "$SR/audit/control.log")" '"action":"svc-restart","status":"failed","keys":"p2pool"'
sr_run "$(sr_req "$(sr_id 32)" '"p2pool"')"
assert_eq "a failed restart does not start the cooldown" "$(sr_status "$(sr_id 32)")" "applied"

if command -v flock >/dev/null 2>&1; then
    : >"$SR_DOCKER_LOG"
    rm -f "$SR/svc-restart-xmrig-proxy"
    : >"$SR/.lock"
    (
        exec 9>>"$SR/.lock"
        flock -w 20 9 || exit 1
        exec sleep 30
    ) >/dev/null 2>&1 &
    sr_holder=$!
    sr_i=0
    while flock -n "$SR/.lock" true 2>/dev/null && [ "$sr_i" -lt 200 ]; do
        sleep 0.05
        sr_i=$((sr_i + 1))
    done
    sr_run "$(sr_req "$(sr_id 40)" '"xmrig-proxy"')"
    assert_eq "a restart while the mutation lock is held is rejected as busy, not queued" "$(sr_status "$(sr_id 40)")" "rejected"
    assert_contains "the busy refusal says another operation is running" "$(jq -r .error "$SR/results/$(sr_id 40).json")" "in progress"
    assert_eq "a busy refusal never reaches docker" "$(cat "$SR_DOCKER_LOG")" ""
    kill "$sr_holder" 2>/dev/null || true
    wait "$sr_holder" 2>/dev/null || true
fi
unset SR SR_DOCKER_LOG
