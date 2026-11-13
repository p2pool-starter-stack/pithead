# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-channel lifecycle-verb domain (#1105 Phase 1, appliance lane): the #33 runner's BOUNDED
# action set. The runner dispatches each accepted verb to a FIXED pithead command and audits it; an
# unknown verb is rejected, and no host command runs on the rejection path.
#
# These verbs reached the spool from the Telegram control commands (#338) until #2076 removed them,
# so `apply` currently has no producer; `restart` is submitted by the dashboard's Restart all
# (#4064). The dispatch table is still the place "a spool writer cannot run an arbitrary host
# command" is proven. The actor below is a plain test tag, not a Telegram user id.
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
    printf '{"step":"%s","version":"v9.9.9"}\n' "$step" >"$CC/results/os-update-state.json"
    restart_refusal_case "restart during OS update step $step" "OS update is in progress ($step)"
done
printf '{"step":"idle"}\n' >"$CC/results/os-update-state.json"
mkdir -p "$CC/os"
printf '{"to":"9.9.9"}\n' >"$CC/os/in-flight.json"
export PITHEAD_OS_UPDATE_DIR="$CC/os" PITHEAD_VERSION="9.9.9"
restart_refusal_case "restart in the uncommitted-slot window" "still being committed"
unset PITHEAD_OS_UPDATE_DIR PITHEAD_VERSION
rm -f "$CC/results/os-update-state.json"
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
