#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck disable=SC2034 # run-state module source guard
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-state.sh
source "$HERE/../lib/run-state.sh"
TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT
OUT_DIR="$TD/results"
TRACE="$TD/commands"
PROBE_RCS=(28 28 28)
DIRECT_RC=28
SOCKS_CALLS=0
ORIGINAL='docker exec monerod curl -s -o /dev/null -m 30 --socks5-hostname 192.0.2.25:9050 http://1.1.1.1/'
env_on_box() { echo 192.0.2; }
rx() {
    printf '%s\n' "$1" >>"$TRACE"
    case "$1" in
    "docker exec monerod sh -c 'command -v curl' >/dev/null 2>&1") return 0 ;;
    'docker exec monerod curl -s -o /dev/null -m 8 http://1.1.1.1/') return "$DIRECT_RC" ;;
    "$ORIGINAL" | 'docker exec monerod curl -s -o /dev/null -m 45 --proxy-user pithead-control-'*' --socks5-hostname 192.0.2.25:9050 http://1.1.1.1/')
        SOCKS_CALLS=$((SOCKS_CALLS + 1))
        SECONDS=$((SECONDS + 30))
        printf '%s\n' 'untrusted endpoint token=probe-secret' >&2
        return "${PROBE_RCS[$((SOCKS_CALLS - 1))]:-${PROBE_RCS[${#PROBE_RCS[@]} - 1]}}"
        ;;
    *) return 125 ;;
    esac
}

reset_probe() {
    PROBE_RCS=("$@")
    SOCKS_CALLS=0
    # shellcheck disable=SC2034 # read by the probe under test
    EGRESS_PROBE_SEQUENCE=0
    : >"$TRACE"
    rm -rf "$OUT_DIR"
}

run_pair() {
    local before=$IT_FAIL
    assert_egress_dial_pair >"$TD/pair.log" 2>&1
    pair_failed=$((IT_FAIL - before))
    IT_FAIL=$before
}

echo "== Every attempt fails: the row stays red, and all three attempts are on record =="
reset_probe 28 28 28
run_pair
assert_eq "failed SOCKS control adds exactly one failed row" "$pair_failed" 1
assert_eq "three SOCKS requests, then stop" "$SOCKS_CALLS" 3
record="$(cat "$OUT_DIR/tor-egress-probes/probe-1.txt")"
assert_eq "sequence 1 is the original record, unchanged" "$record" \
    'original-socks-probe sequence=1 exit=28 elapsed_s=30 class=timeout-stage-unknown stage=unknown'
assert_eq "sequence 1 ran the original command" "$(grep -m1 -F -- '--socks5-hostname' "$TRACE")" "$ORIGINAL"
assert_contains "attempt 2 is recorded under its own sequence" "$(cat "$OUT_DIR/tor-egress-probes/probe-2.txt")" \
    'retry-socks-probe sequence=2 exit=28 elapsed_s=30 class=timeout-stage-unknown stage=unknown attempt=2'
assert_contains "attempt 3 is recorded under its own sequence" "$(cat "$OUT_DIR/tor-egress-probes/probe-3.txt")" \
    'sequence=3 exit=28'
assert_eq "retries carry distinct SOCKS users" \
    "$(grep -o -- '--proxy-user [^ ]*' "$TRACE" | sort -u | wc -l | tr -d ' ')" 2
assert_eq "no retry reuses the original request" "$(grep -cF -- "$ORIGINAL" "$TRACE")" 1
diagnostic_line="$(grep -nF "$record" "$TD/pair.log" | cut -d: -f1)"
verdict_line="$(grep -n '✗ the same container still reaches clearnet THROUGH Tor' "$TD/pair.log" | cut -d: -f1)"
if [[ "$diagnostic_line" =~ ^[0-9]+$ ]] && [[ "$verdict_line" =~ ^[0-9]+$ ]] &&
    [ "$diagnostic_line" -lt "$verdict_line" ]; then
    it_pass "original record precedes the failed verdict in the transcript"
else
    it_fail "original record precedes the failed verdict in the transcript" "missing or late record"
fi
assert_contains "the failure names all three attempts" "$(cat "$TD/pair.log")" \
    'all 3 attempts failed; attempt 1 exit=28 class=timeout-stage-unknown; attempt 2 exit=28 class=timeout-stage-unknown; attempt 3 exit=28 class=timeout-stage-unknown'
if grep -qE 'probe-secret|untrusted endpoint' "$TD/pair.log" ||
    grep -q '192\.0\.2' "$OUT_DIR"/tor-egress-probes/*.txt; then
    it_fail "diagnostic records exclude raw output and topology" "unexpected raw probe output"
else
    it_pass "diagnostic records exclude raw output and topology"
fi

echo "== A transient failure then a success passes, and names the attempt that connected =="
reset_probe 52 0
run_pair
assert_eq "a flake adds no failed row" "$pair_failed" 0
assert_eq "the first success stops the loop" "$SOCKS_CALLS" 2
assert_contains "the pass names the attempt and the failure before it" "$(cat "$TD/pair.log")" \
    '✓ the same container still reaches clearnet THROUGH Tor — the drop above is the firewall, not a dead route (#270/#2059) — passed on attempt 2 of 3; attempt 1 exit=52 class=empty-reply'
assert_eq "the original failure stays on record after the retry passes" \
    "$(cat "$OUT_DIR/tor-egress-probes/probe-1.txt")" \
    'original-socks-probe sequence=1 exit=52 elapsed_s=30 class=empty-reply stage=unknown'
assert_contains "the passing retry is recorded too" "$(cat "$OUT_DIR/tor-egress-probes/probe-2.txt")" 'sequence=2 exit=0'

echo "== A first-attempt success never retries and keeps the row name =="
reset_probe 0
run_pair
assert_eq "success adds no failed row" "$pair_failed" 0
assert_eq "no retry after a success" "$SOCKS_CALLS" 1
assert_contains "the row name is unchanged" "$(cat "$TD/pair.log")" \
    '✓ the same container still reaches clearnet THROUGH Tor — the drop above is the firewall, not a dead route (#270/#2059)'
if grep -q 'passed on attempt' "$TD/pair.log"; then
    it_fail "a first-attempt pass names no retry" "retry text on a first-attempt pass"
else
    it_pass "a first-attempt pass names no retry"
fi
assert_eq "the DROP dial is single-shot" "$(grep -cF -- '-m 8 http://1.1.1.1/' "$TRACE")" 1

echo "== Target/transport ambiguity and artifact errors preserve the original status =="
reset_probe 255
OUT_DIR="$TD/not-a-directory"
printf x >"$OUT_DIR"
probe_rc=0
run_egress_socks_probe 192.0.2.25:9050 >"$TD/unavailable.log" 2>&1 || probe_rc=$?
assert_eq "diagnostic write failure preserves target/transport exit" "$probe_rc" 255
assert_contains "transport ambiguity is explicit" "$(cat "$TD/unavailable.log")" 'class=target-or-ssh-failed'
assert_contains "unavailable artifact is reported" "$(cat "$TD/unavailable.log")" 'artifact unavailable'
assert_contains "original artifact failure keeps its label" "$(cat "$TD/unavailable.log")" \
    'original-socks-probe sequence=1 artifact unavailable; original status retained in transcript'
assert_contains "retry artifact failure keeps its label" "$(cat "$TD/unavailable.log")" \
    'retry-socks-probe sequence=2 artifact unavailable; original status retained in transcript'
if grep -qF "$TD" "$TD/unavailable.log"; then
    it_fail "artifact errors do not expose filesystem paths" "raw path in transcript"
else
    it_pass "artifact errors do not expose filesystem paths"
fi
reset_probe 97
OUT_DIR="$TD/not-a-directory"
printf x >"$OUT_DIR"
run_pair
assert_eq "missing artifact never converts failed proxy control to pass" "$pair_failed" 1
assert_contains "handshake failure keeps original exit" "$(cat "$TD/pair.log")" 'exit=97'

echo "== Exit classes do not reinterpret the original status =="
OUT_DIR="$TD/classes"
while read -r rc expected_class; do
    reset_probe "$rc"
    probe_rc=0
    run_egress_socks_probe 192.0.2.25:9050 >"$TD/class.log" || probe_rc=$?
    assert_eq "original status $rc survives classification" "$probe_rc" "$rc"
    assert_contains "status $rc has its bounded class" "$(cat "$TD/class.log")" "class=$expected_class stage=unknown"
done <<'CLASSES'
7 connect-failed
52 empty-reply
56 receive-or-socks-failed
125 execution-failed
126 execution-failed
127 execution-failed
42 unclassified
CLASSES

echo "selftest-egress-probe: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
