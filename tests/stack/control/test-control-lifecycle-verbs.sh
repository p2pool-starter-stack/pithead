# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-channel lifecycle-verb domain (#1105 Phase 1, appliance lane): the #33 runner's BOUNDED
# action set. The runner dispatches each accepted verb to a FIXED pithead command and audits it; an
# unknown verb is rejected, and no host command runs on the rejection path.
#
# These verbs reached the spool from the Telegram control commands (#338) until #2076 removed them,
# so `restart` and `apply` currently have NO producer — the dashboard never submits either. The
# dispatch table is still live code and still the place "a spool writer cannot run an arbitrary
# host command" is proven, so the domain is kept and renamed rather than deleted with its old
# caller. The actor below is a plain test tag now, not a Telegram user id.
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
unset PITHEAD_SELF SELF_LOG

echo "== control channel: svc-restart — one allowlisted service, under the lock, with a cooldown (#4062) =="
SR="$SANDBOX/ctrl4062"
mkdir -p "$SR/results" "$SR/audit" "$SR/bin"
cat >"$SR/bin/docker" <<'EOF2'
#!/usr/bin/env bash
echo "$*" >>"$SR_DOCKER_LOG"
[ "${SR_DOCKER_RC:-0}" -eq 0 ] || { echo "no such service" >&2; exit "$SR_DOCKER_RC"; }
exit 0
EOF2
chmod +x "$SR/bin/docker"
export SR SR_DOCKER_LOG="$SR/docker.log"
sr_req() { # <id> <container-json-fragment> [extra]
    printf '{"id":"%s","action":"svc-restart","actor":"admin"%s%s}\n' "$1" "${2:+,\"container\":$2}" "${3:-}" >"$SR/req-$1.json"
    printf '%s\n' "$SR/req-$1.json"
}
sr_run() { # <request-file> [guard-ready: 1|0]
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
assert_eq "the restart runs exactly one compose restart of that service" "$(cat "$SR_DOCKER_LOG")" "compose restart tor"
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

sr_allowed=""
for svc in wallet-rpc tari tari-wallet p2pool xmrig-proxy; do
    : >"$SR_DOCKER_LOG"
    sr_run "$(sr_req "$(sr_id 10)" "\"$svc\"")"
    sr_allowed+="$(cat "$SR_DOCKER_LOG")"$'\n'
    rm -f "$SR/results/$(sr_id 10).json"
done
assert_eq "every other allowlisted service restarts with exactly one compose restart" "$sr_allowed" \
    $'compose restart wallet-rpc\ncompose restart tari\ncompose restart tari-wallet\ncompose restart p2pool\ncompose restart xmrig-proxy\n'

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
