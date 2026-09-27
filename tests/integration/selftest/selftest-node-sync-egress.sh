#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
echo "== node-sync egress verifier (#2678) =="
# The node-sync arm is the tier-4 clearnet window's positive and negative control: both chosen
# daemons must have real outbound public sockets, while p2pool remains isolated.
# shellcheck disable=SC2016 # fixture script expands these variables when the fake docker runs
if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    printf '%s\n' '#!/bin/sh' \
        'if [ "$1 $2 $3" = "compose config --services" ]; then printf "monerod\ntari\np2pool\ntor\n"; exit 0; fi' \
        'if [ "$1 $2 $3" = "compose ps -q" ]; then echo "$4"; exit 0; fi' \
        'if [ "$1" = exec ]; then' \
        '  printf "  sl local_address rem_address st\n"' \
        '  case "$2" in monerod|tari|tor) printf "0: 00000000:ABCD 08080808:0050 01\n" ;;' \
        '    p2pool) [ "${P2POOL_LEAK:-0}" != 1 ] || printf "0: 00000000:ABCD 08080808:0050 01\n" ;; esac' \
        '  exit 0' \
        'fi' 'exit 125' >"$td/docker" && chmod +x "$td/docker"
    PATH="$td:$PATH" bash "$HERE/benchmarks/bench-verify-egress.sh" node-sync --dir "$td" --polls 2 --interval 0 >/dev/null 2>&1 &&
        P2POOL_LEAK=1 PATH="$td:$PATH" bash "$HERE/benchmarks/bench-verify-egress.sh" node-sync --dir "$td" --polls 2 --interval 0 >"$td/leak.log" 2>&1
    [ "$?" -eq 1 ] && grep -qF '[verify-egress] FAIL' "$td/leak.log"
); then
    echo "node-sync verifier proves selected public peers and rejects another app's leak: PASS"
else
    echo "node-sync verifier proves selected public peers and rejects another app's leak: FAIL" >&2
    exit 1
fi
