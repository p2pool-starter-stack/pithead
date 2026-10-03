#!/usr/bin/env bash
# Original SOCKS-probe diagnostics and unchanged firewall-control verdicts (#812).
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
PROBE_RC=28
DIRECT_RC=28
SOCKS_CALLS=0
env_on_box() { echo 192.0.2; }
rx() {
    printf '%s\n' "$1" >>"$TRACE"
    case "$1" in
    "docker exec monerod sh -c 'command -v curl' >/dev/null 2>&1") return 0 ;;
    'docker exec monerod curl -s -o /dev/null -m 8 http://1.1.1.1/') return "$DIRECT_RC" ;;
    'docker exec monerod curl -s -o /dev/null -m 30 --socks5-hostname 192.0.2.25:9050 http://1.1.1.1/')
        SOCKS_CALLS=$((SOCKS_CALLS + 1))
        SECONDS=$((SECONDS + 30))
        printf '%s\n' 'untrusted endpoint token=probe-secret' >&2
        return "$PROBE_RC"
        ;;
    *) return 125 ;;
    esac
}

echo "== A failed original control remains red, with its own one-shot record =="
before=$IT_FAIL
assert_egress_dial_pair >"$TD/failed.log"
observed=$IT_FAIL
# Discard only the expected failure count after checking it; never hide a test failure.
IT_FAIL=$before
assert_eq "failed SOCKS control adds exactly one failed row" "$observed" "$((before + 1))"
assert_eq "exact original SOCKS command executes once" "$SOCKS_CALLS" 1
record="$(cat "$OUT_DIR/tor-egress-probes/probe-1.txt")"
assert_eq "original timeout is correlated, without an invented stage" "$record" \
    'original-socks-probe sequence=1 exit=28 elapsed_s=30 class=timeout-stage-unknown stage=unknown'
diagnostic_line="$(grep -nF "$record" "$TD/failed.log" | cut -d: -f1)"
verdict_line="$(grep -n '✗ the same container still reaches clearnet THROUGH Tor' "$TD/failed.log" | cut -d: -f1)"
if [[ "$diagnostic_line" =~ ^[0-9]+$ ]] && [[ "$verdict_line" =~ ^[0-9]+$ ]] &&
    [ "$diagnostic_line" -lt "$verdict_line" ]; then
    it_pass "original record precedes the failed verdict in the transcript"
else
    it_fail "original record precedes the failed verdict in the transcript" "missing or late record"
fi
assert_contains "original firewall-control row remains red" "$(cat "$TD/failed.log")" \
    '✗ the same container still reaches clearnet THROUGH Tor'
if grep -qE 'probe-secret|untrusted endpoint' "$TD/failed.log" ||
    grep -q '192\.0\.2' "$OUT_DIR/tor-egress-probes/probe-1.txt"; then
    it_fail "diagnostic record excludes raw output and topology" "unexpected raw probe output"
else
    it_pass "diagnostic record excludes raw output and topology"
fi

echo "== A later successful request cannot overwrite the original failure =="
PROBE_RC=0
assert_egress_dial_pair >"$TD/passed.log"
assert_eq "later success retains original failure evidence" "$(cat "$OUT_DIR/tor-egress-probes/probe-1.txt")" "$record"
assert_contains "later success has a distinct sequence" "$(cat "$OUT_DIR/tor-egress-probes/probe-2.txt")" 'sequence=2 exit=0'
assert_contains "success still passes the same control" "$(cat "$TD/passed.log")" \
    '✓ the same container still reaches clearnet THROUGH Tor'
assert_eq "two controls issued exactly two SOCKS requests" "$SOCKS_CALLS" 2

echo "== Target/transport ambiguity and artifact errors preserve original status =="
PROBE_RC=255
OUT_DIR="$TD/not-a-directory"
printf x >"$OUT_DIR"
probe_rc=0
run_egress_socks_probe 192.0.2.25:9050 >"$TD/unavailable.log" 2>&1 || probe_rc=$?
assert_eq "diagnostic write failure preserves target/transport exit" "$probe_rc" 255
assert_contains "transport ambiguity is explicit" "$(cat "$TD/unavailable.log")" 'class=target-or-ssh-failed'
assert_contains "unavailable artifact is reported" "$(cat "$TD/unavailable.log")" 'artifact unavailable'
if grep -qF "$TD" "$TD/unavailable.log"; then
    it_fail "artifact errors do not expose filesystem paths" "raw path in transcript"
else
    it_pass "artifact errors do not expose filesystem paths"
fi
PROBE_RC=97
before=$IT_FAIL
assert_egress_dial_pair >"$TD/unavailable-row.log" 2>&1
observed=$IT_FAIL
IT_FAIL=$before
assert_eq "missing artifact never converts failed proxy control to pass" "$observed" "$((before + 1))"
assert_contains "handshake failure keeps original exit" "$(cat "$TD/unavailable-row.log")" 'exit=97'
assert_eq "diagnostics never issue a replacement probe" "$SOCKS_CALLS" 4

echo "== Exit classes do not reinterpret the original status =="
OUT_DIR="$TD/classes"
while read -r PROBE_RC expected_class; do
    probe_rc=0
    run_egress_socks_probe 192.0.2.25:9050 >"$TD/class.log" || probe_rc=$?
    assert_eq "original status $PROBE_RC survives classification" "$probe_rc" "$PROBE_RC"
    assert_contains "status $PROBE_RC has its bounded class" "$(cat "$TD/class.log")" "class=$expected_class stage=unknown"
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
