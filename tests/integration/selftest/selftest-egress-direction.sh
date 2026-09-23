#!/usr/bin/env bash
#
# Self-test for bench-verify-egress.sh naming each persistent public socket's DIRECTION (#2549).
#
# Bench job 814 FAILed the Tor-down row with "tari: 2 PERSISTENT PUBLIC connection(s) — CLEARNET
# LEAK" while Tari's own log read OFFLINE (0 peer connections) all phase. The verifier had dropped
# both ports, so nothing could say whether Tari dialled out or a client reached its published
# gRPC listener. It now labels each socket; these cases pin that the label never waives the FAIL.
#
# A separate file because selftest-live-gates.sh, which holds the verifier's other fixtures, sits
# ON its lint-file-budget ceiling; the runner globs selftest/*.sh (Makefile:43).
#
# Run: tests/integration/selftest/selftest-egress-direction.sh
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="$SELF/.."
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

# The fixture is tari's netns: a gRPC listener on 18142 (IPv4 table, or the IPv6 one), a client
# from 198.51.100.43 accepted on it, and optionally a dial from an ephemeral port to
# 198.51.100.42:853. Tor shares the table, so its relay control holds. Either way the tor arm still
# FAILs: the label says which kind, it waives nothing.
direction_fixture() { # <socket table> -> rc, output on stdout
    td="$(mktemp -d)"
    printf '%s\n' "$1" >"$td/tcp"
    printf '%s\n' '#!/bin/sh' \
        'if [ "$1 $2 $3" = "compose config --services" ]; then printf "tari\ntor\n"; exit 0; fi' \
        'if [ "$1 $2 $3" = "compose ps -q" ]; then echo cid; exit 0; fi' \
        "if [ \"\$1\" = exec ]; then cat '$td/tcp'; exit 0; fi" \
        'exit 125' >"$td/docker" && chmod +x "$td/docker"
    PATH="$td:$PATH" bash "$HERE/benchmarks/bench-verify-egress.sh" tor --dir "$td" --polls 1 --interval 0 2>&1
    rc=$?
    rm -rf "$td"
    return "$rc"
}
tcp_head="  sl  local_address rem_address st"
tcp_listen="0: 00000000:46DE 00000000:0000 0A"
tcp_in="1: 1B001CAC:46DE 2B6433C6:C350 01"
tcp_out="2: 1B001CAC:9C40 2A6433C6:0355 01"
tcp6_listen="3: 00000000000000000000000000000000:46DE 00000000000000000000000000000000:0000 0A"
out="$(direction_fixture "$(printf '%s\n' "$tcp_head" "$tcp_listen" "$tcp_in" "$tcp_out")")"
rc=$?
if [ "$rc" = 1 ] && [[ "$out" == *"CLEARNET LEAK"* ]] &&
    [[ "$out" == *"198.51.100.42 (1/1 polls) outbound to port 853"* ]] &&
    [[ "$out" == *"198.51.100.43 (1/1 polls) inbound on listening port 18142"* ]]; then
    it_pass "an app's direct dial is still a CLEARNET LEAK, beside an inbound client on its listener (#2549)"
else
    it_fail "an app's direct dial is still a CLEARNET LEAK, beside an inbound client on its listener (#2549)" "rc=$rc"
fi
out="$(direction_fixture "$(printf '%s\n' "$tcp_head" "$tcp6_listen" "$tcp_in")")"
rc=$?
if [ "$rc" = 1 ] && [[ "$out" != *"CLEARNET LEAK"* ]] && [[ "$out" != *outbound* ]] &&
    [[ "$out" == *"198.51.100.43 (1/1 polls) inbound on listening port 18142"* ]]; then
    it_pass "a public client on a listening port FAILs as inbound, not as an app's clearnet dial (#2549)"
else
    it_fail "a public client on a listening port FAILs as inbound, not as an app's clearnet dial (#2549)" "rc=$rc"
fi

echo "selftest-egress-direction: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
