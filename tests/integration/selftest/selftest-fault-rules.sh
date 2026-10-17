#!/usr/bin/env bash
#
# Self-test for the e2e fault-rule teardown (lib/fault-rules.sh): stale pithead-e2e-fault-* rules are
# removed before a fault leg injects its own and when the harness is terminated, and nothing else is
# touched. docker, sudo, nsenter and iptables are stubs over per-namespace rule files: no box.
#
set -uo pipefail

echo "== selftest: e2e fault-rule teardown =="

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
# shellcheck source=tests/integration/lib.sh
source "$ROOT/lib.sh"
# shellcheck source=tests/integration/lib/fault-rules.sh
source "$ROOT/lib/fault-rules.sh"
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-tari-stranded.sh
source "$ROOT/lib/run-tari-stranded.sh"
# shellcheck source=tests/integration/lib/run-monero-stranded.sh
source "$ROOT/lib/run-monero-stranded.sh"
# shellcheck source=tests/integration/lib/run-faults.sh
source "$ROOT/lib/run-faults.sh"

FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
mkdir -p "$FAKE/bin"
export FAKE
export PATH="$FAKE/bin:$PATH"
IT_MODE=local
IT_REMOTE_DIR="$FAKE"

cat >"$FAKE/bin/docker" <<'STUB'
#!/usr/bin/env bash
find_row() { awk -v k="$1" '$1 == k || $3 == k' "$FAKE/containers"; }
case "$1" in
ps) awk '{print $1}' "$FAKE/containers" ;;
inspect)
    fmt=$3 key=${@: -1}
    row=$(find_row "$key") || exit 1
    [ -n "$row" ] || exit 1
    set -- $row
    case "$fmt" in *.Name*) echo "$2 /$3" ;; *) echo "$2" ;; esac
    ;;
esac
STUB
cat >"$FAKE/bin/sudo" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -n ] && shift
exec "$@"
STUB
cat >"$FAKE/bin/nsenter" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -t ] && [ "$3" = -n ] || exit 2
[ -f "$FAKE/ns-$2.rules" ] || exit 1
pid=$2
shift 3
FAKE_NS_PID=$pid exec "$@"
STUB
cat >"$FAKE/bin/iptables" <<'STUB'
#!/usr/bin/env bash
f="$FAKE/ns-$FAKE_NS_PID.rules"
echo "$FAKE_NS_PID: $*" >>"$FAKE/calls"
norm() { tr -d '"'; }
case "$1" in
-S)
    printf '%s\n' '-P INPUT ACCEPT' '-P FORWARD ACCEPT' '-P OUTPUT ACCEPT'
    cat "$f"
    ;;
-I)
    shift
    { printf '%s\n' "-A $*"; cat "$f"; } >"$f.new"
    mv "$f.new" "$f"
    ;;
-C)
    shift
    [ "${FAKE_REFUSE_CHECK:-0}" = 1 ] && exit 1
    printf '%s\n' "-A $*" | norm | grep -Fxqf - <(norm <"$f")
    ;;
-D)
    shift
    [ "${FAKE_REFUSE_DELETE:-0}" = 1 ] && exit 1
    want="-A $*"
    n=0
    out=
    while IFS= read -r line; do
        if [ "$n" = 0 ] && [ "$(printf '%s' "$line" | norm)" = "$(printf '%s' "$want" | norm)" ]; then
            n=1
            continue
        fi
        out+="$line"$'\n'
    done <"$f"
    [ "$n" = 1 ] || exit 1
    printf '%s' "$out" >"$f"
    ;;
-L)
    echo 'Chain OUTPUT (policy ACCEPT)'
    echo ' pkts bytes target prot opt in out source destination'
    grep -E 'pithead-e2e-fault-' "$f" | sed 's/^/7 420 /'
    ;;
*) exit 99 ;;
esac
STUB
chmod +x "$FAKE/bin/"*

DASH='-A OUTPUT -d 172.28.0.25/32 -p tcp -m tcp --dport 9050 -m comment --comment pithead-e2e-fault-tor-probe -j DROP'
TARI='-A OUTPUT -d 172.28.0.5/32 -m comment --comment pithead-e2e-fault-tari-stranded -j DROP'
KEEP1='-A OUTPUT -d 198.51.100.7/32 -j DROP'
KEEP2='-A OUTPUT -m comment --comment keep-me -j ACCEPT'
KEEP3='-A OUTPUT -m comment --comment "see pithead-e2e-fault-x" -j ACCEPT'
KEEP4='-A DOCKER-USER -m comment --comment pithead-tor-egress -j DROP'

reset_fake() {
    printf '%s\n' 'd1 4242 dashboard' 't1 4343 tari' 'm1 4444 monerod' 's1 0 stopped' >"$FAKE/containers"
    printf '%s\n' "$DASH" "$KEEP1" "$KEEP2" >"$FAKE/ns-4242.rules"
    printf '%s\n' "$TARI" "$KEEP3" "$KEEP4" >"$FAKE/ns-4343.rules"
    printf '%s\n' "$KEEP1" >"$FAKE/ns-4444.rules"
    : >"$FAKE/calls"
    rm -f "$FAKE/trap.out"
}
tagged() { cat "$FAKE"/ns-*.rules | grep -cE -- '--comment "?pithead-e2e-fault-'; }

echo "== the helper removes tagged rules and only those =="
reset_fake
out="$(fault_rules_clear_all 2>&1)"
assert_eq "no tagged rule survives in any namespace" "$(tagged)" "0"
assert_eq "the dashboard namespace keeps exactly its untagged rules" "$(cat "$FAKE/ns-4242.rules")" "$(printf '%s\n%s' "$KEEP1" "$KEEP2")"
assert_eq "the tari namespace keeps a quoted comment that only mentions the tag and an unrelated chain" \
    "$(cat "$FAKE/ns-4343.rules")" "$(printf '%s\n%s' "$KEEP3" "$KEEP4")"
assert_eq "a namespace without a tagged rule is unchanged" "$(cat "$FAKE/ns-4444.rules")" "$KEEP1"
assert_contains "the removal names the container and the tag" "$out" "removed fault rule: dashboard pithead-e2e-fault-tor-probe"
assert_contains "and the other container's rule" "$out" "removed fault rule: tari pithead-e2e-fault-tari-stranded"
assert_eq "every change is a single -D OUTPUT of a listed rule" "$(grep -c ': -D OUTPUT ' "$FAKE/calls")" "2"
assert_eq "nothing is flushed, deleted by chain, inserted or re-policed" "$(grep -cE ': -(F|X|P|A|I)( |$)' "$FAKE/calls")" "0"
assert_eq "a container that is not running is never entered" "$(grep -c '^0:' "$FAKE/calls")" "0"

echo "== the scan needs nothing beyond a POSIX sh, not bash =="
reset_fake
sh -c "prefix=$FAULT_RULE_PREFIX; $(fault_rules_snippet)" >"$FAKE/sh.out" 2>&1
assert_eq "sh removes the same two rules" "$(grep -c '^removed ' "$FAKE/sh.out")" "2"
assert_eq "and leaves no tagged rule" "$(tagged)" "0"

echo "== a second run is a no-op =="
: >"$FAKE/calls"
out="$(fault_rules_clear_all 2>&1)"
assert_eq "no output when nothing is tagged" "$out" ""
assert_eq "only listings were issued" "$(grep -vc ': -S$' "$FAKE/calls")" "0"

echo "== a quoted comment and several tagged rules in one namespace =="
reset_fake
printf '%s\n' "$DASH" '-A OUTPUT -d 172.28.0.9/32 -m comment --comment "pithead-e2e-fault-tari-stranded" -j DROP' "$KEEP2" '-A OUTPUT -m comment --comment pithead-e2e-fault-monero-stranded -j DROP' >"$FAKE/ns-4242.rules"
fault_rules_clear_all >/dev/null 2>&1
assert_eq "all three are removed and the untagged rule stays" "$(cat "$FAKE/ns-4242.rules")" "$KEEP2"

echo "== a rule that will not delete is reported and left =="
reset_fake
out="$(FAKE_REFUSE_DELETE=1 fault_rules_clear_all 2>&1)"
rc=$?
assert_rc "the helper still returns 0" "$rc" "0"
assert_contains "the failure names the container and the tag" "$out" "fault rule could not be removed: dashboard pithead-e2e-fault-tor-probe"
assert_eq "the rule is still there" "$(grep -c 'pithead-e2e-fault-tor-probe' "$FAKE/ns-4242.rules")" "1"
assert_eq "one delete was tried per namespace, not a loop" "$(grep -c ': -D ' "$FAKE/calls")" "2"

echo "== no running container answers with nothing and fails nothing =="
reset_fake
: >"$FAKE/containers"
assert_eq "no container, no change" "$(fault_rules_clear_all 2>&1)" ""
assert_eq "and the rules stay" "$(tagged)" "2"

echo "== the EXIT trap composes with the one already installed =="
reset_fake
sub="$(
    trap 'echo foreign-ran' EXIT
    fault_rules_trap_arm
    fault_rules_trap_arm
    cur="$(trap -p EXIT)"
    [ "$(grep -o fault_rules_exit <<<"$cur" | grep -c .)" = 1 ] && echo armed
    fault_rules_trap_disarm
    cur="$(trap -p EXIT)"
    case "$cur" in *foreign-ran*) echo restored ;; esac
    fault_rules_trap_disarm
    cur="$(trap -p EXIT)"
    case "$cur" in *foreign-ran*) echo untouched ;; esac
    fault_rules_trap_arm
    exit 3
)"
rc=$?
assert_contains "arming twice installs one handler" "$sub" "armed"
assert_contains "disarming gives the earlier trap back" "$sub" "restored"
assert_contains "disarming without arming leaves the earlier trap alone" "$sub" "untouched"
assert_contains "the earlier trap still runs at exit, after the cleanup" "$sub" "foreign-ran"
assert_eq "the exit status is the script's own" "$rc" "3"
assert_eq "the exit cleanup removed the rules" "$(tagged)" "0"

echo "== the stranded legs clear through the shared helper =="
reset_fake
(
    fault_rules_clear_all() { echo clear; }
    tari_restore_config() { echo restore; }
    monero_restore_config() { echo restore; }
    tari_strand_abort
    monero_strand_abort
) >"$FAKE/abort.out" 2>&1
assert_eq "tari and monero abort handlers clear then restore" "$(tr '\n' ' ' <"$FAKE/abort.out")" "clear restore clear restore "
(
    trap - EXIT
    CALLS="$FAKE/tari.calls"
    BASELINE_CONFIG='{}'
    : >"$CALLS"
    fault_rules_clear_all() { echo clear >>"$CALLS"; }
    has_compose_profile() { return 0; }
    env_on_box() { :; }
    tari_hook_start() { :; }
    tari_restore_config() { :; }
    push_config() { :; }
    wait_status_ok() { return 0; }
    wait_for() { return 0; }
    tari_health_field() { echo green; }
    tari_strand_state() { echo state; }
    tari_started_at() { echo T; }
    tari_strand_count() { echo 1; }
    tari_strand_drops() { echo 0; }
    tari_ns_ipt() { echo "ns $*" >>"$CALLS"; }
    now_s() { echo 0; }
    sleep() { :; }
    pithead() { [ "$1" != doctor ]; }
    api_state() { echo '{}'; }
    capture_artifacts() { :; }
    rx() { case "$1" in *"docker inspect -f '{{range"*) echo 172.28.0.5 ;; esac }
    run_tari_stranded
) >"$FAKE/tari.out" 2>&1
assert_eq "the tari leg clears stale rules before it injects its own" "$(grep -n 'clear\|ns -I' "$FAKE/tari.calls" | head -2 | cut -d: -f2 | tr '\n' ' ')" "clear ns -I OUTPUT -d 172.28.0.5 -m comment --comment pithead-e2e-fault-tari-stranded -j DROP "

echo "== the fault-injection phase clears at its start and again once the stack is back up =="
reset_fake
(
    LOG="$FAKE/phase.log"
    : >"$LOG"
    has_compose_profile() { return 0; }
    env_on_box() { echo /data; }
    wait_for() { return 0; }
    wait_status_ok() { return 0; }
    capture_artifacts() { :; }
    rx() { echo "rx $1" >>"$LOG"; }
    fault_rules_clear_all() { echo clear >>"$LOG"; }
    for leg in $(declare -F | awk '$3 ~ /^fault_/ && $3 !~ /^fault_rules_/ {print $3}'); do
        eval "$leg() { echo $leg >>\"\$LOG\"; }"
    done
    run_fault_injection
) >/dev/null 2>&1
assert_eq "the phase clears before its first leg injects" "$(head -n1 "$FAKE/phase.log")" "clear"
assert_eq "and clears between bringing Tor back and restarting the dashboard" \
    "$(sed -n '/^rx docker compose up -d tor$/,/^rx docker compose restart dashboard$/p' "$FAKE/phase.log" | grep -c '^clear$')" "1"
assert_eq "no leg-specific rule delete is left in the phase" "$(grep -c 'pithead-e2e-fault' "$FAKE/phase.log")" "0"

echo "== every leg tags its rule with the prefix the sweep looks for =="
assert_eq "tari-stranded" "${TARI_STRAND_TAG#"$FAULT_RULE_PREFIX"}" "tari-stranded"
assert_eq "monero-stranded" "${MONERO_STRAND_TAG#"$FAULT_RULE_PREFIX"}" "monero-stranded"
assert_eq "tor-probe" "$(grep -ohE "${FAULT_RULE_PREFIX}[a-z-]*" "$ROOT/lib/run-tor-probe-fault.sh" | sort -u)" "${FAULT_RULE_PREFIX}tor-probe"

echo "== the Tor-probe leg =="
cat >"$FAKE/victim.sh" <<'VICTIM'
set -uo pipefail
source "$ROOT/lib.sh"
INTEGRATION_RUN_SUITE=1
source "$ROOT/lib/fault-rules.sh"
source "$ROOT/lib/run-tor-probe-fault.sh"
[ "${NO_TRAP:-0}" != 1 ] || fault_rules_trap_arm() { :; }
IT_MODE=local
IT_REMOTE_DIR=$FAKE
BASELINE_CONFIG='{}'
env_on_box() { case "$1" in NETWORK_PREFIX) echo 172.28.0 ;; *) echo true ;; esac; }
wait_for() { return 0; }
_tor_probe_mining_sample() { echo 100; }
push_config() { return 0; }
pithead() { return 0; }
wait_status_ok() { return 0; }
sleep() {
    [ "${FAST:-0}" != 1 ] || return 0
    echo IN_LOOP >>"$FAKE/marker"
    command sleep 30
}
fault_tor_probe_egress
printf '%s\n' "$(trap -p EXIT)" >"$FAKE/trap.out"
VICTIM
run_victim() { # <NO_TRAP value> [signal]: start the leg, wait for its fault window, then signal its group
    local pid spun=0
    : >"$FAKE/marker"
    set -m
    ROOT="$ROOT" NO_TRAP="$1" bash "$FAKE/victim.sh" >"$FAKE/victim.out" 2>&1 &
    pid=$!
    set +m
    while ! grep -q IN_LOOP "$FAKE/marker" 2>/dev/null; do
        sleep 0.05
        spun=$((spun + 1))
        [ "$spun" -gt 600 ] && break
    done
    kill -"${2:-TERM}" -- "-$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    VICTIM_RC=$?
}

reset_fake
STALE='-A OUTPUT -d 172.28.0.99/32 -p tcp -m tcp --dport 9050 -m comment --comment pithead-e2e-fault-tor-probe -j DROP'
printf '%s\n' "$STALE" "$KEEP1" "$KEEP2" >"$FAKE/ns-4242.rules"
run_victim 0
first_del="$(grep -n ': -D OUTPUT .*172.28.0.99' "$FAKE/calls" | head -1 | cut -d: -f1)"
first_ins="$(grep -n ': -I OUTPUT' "$FAKE/calls" | head -1 | cut -d: -f1)"
[ -n "$first_ins" ] || first_ins=0
[ -n "$first_del" ] || first_del=999
if [ "$first_del" -lt "$first_ins" ]; then
    it_pass "a stale tagged rule is deleted before the leg inserts its own"
else
    it_fail "a stale tagged rule is deleted before the leg inserts its own" "delete at call $first_del, insert at call $first_ins"
fi
assert_eq "the leg reached its fault window" "$(grep -c IN_LOOP "$FAKE/marker")" "1"
assert_eq "a TERM during the Tor-probe leg leaves zero tagged rules" "$(tagged)" "0"
assert_eq "and the untagged rules in that namespace are intact" "$(cat "$FAKE/ns-4242.rules")" "$(printf '%s\n%s' "$KEEP1" "$KEEP2")"
assert_eq "the harness died of the TERM, it did not carry on" "$VICTIM_RC" "143"

reset_fake
run_victim 1
assert_eq "control: without the trap the TERM leaves the rule behind, so the instrument can see a leak" "$(grep -c 'pithead-e2e-fault-tor-probe' "$FAKE/ns-4242.rules")" "1"

reset_fake
run_victim 0 INT
assert_eq "an INT during the Tor-probe leg leaves zero tagged rules" "$(tagged)" "0"
assert_eq "and the harness died of the INT" "$VICTIM_RC" "130"

reset_fake
: >"$FAKE/ns-4242.rules"
FAST=1 ROOT="$ROOT" bash "$FAKE/victim.sh" >"$FAKE/victim.out" 2>&1
assert_eq "a leg that runs to the end inserts and deletes its rule" "$(grep -cE '^4242: -[ID] OUTPUT' "$FAKE/calls")" "2"
assert_eq "and leaves no EXIT trap of its own behind" "$(grep -c fault_rules_exit "$FAKE/trap.out")" "0"

reset_fake
: >"$FAKE/ns-4242.rules"
FAST=1 FAKE_REFUSE_CHECK=1 ROOT="$ROOT" bash "$FAKE/victim.sh" >"$FAKE/victim.out" 2>&1
assert_eq "a leg whose rule does not verify deletes it" "$(grep -cE '^4242: -[ID] OUTPUT' "$FAKE/calls")" "2"
assert_eq "and leaves no EXIT trap of its own behind" "$(grep -c fault_rules_exit "$FAKE/trap.out")" "0"

echo "selftest-fault-rules: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
