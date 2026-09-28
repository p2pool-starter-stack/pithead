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

# Host completion must inspect the active daemon's Tor endpoint, not a stray SOCKS setting.
if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    scripts/build-pithead.sh >/dev/null
    # shellcheck disable=SC1091
    source ./pithead
    env_get() { [ "$1" = NETWORK_PREFIX ] && echo 172.28.0; }
    docker() { cat "$td/$2"; }
    printf 'proxy=172.28.0.24:9050\n' >"$td/monerod"
    ! egress_sync_runtime_on_tor monero || exit 1
    printf 'proxy=172.28.0.25:9050\n' >"$td/monerod"
    egress_sync_runtime_on_tor monero || exit 1
    cat >"$td/tari" <<'TARI_BAD'
[base_node.p2p.transport]
type = "tcp"
[unrelated]
type = "socks5"
proxy_address = "/ip4/172.28.0.25/tcp/9050"
TARI_BAD
    ! egress_sync_runtime_on_tor tari || exit 1
    cat >"$td/tari" <<'TARI_GOOD'
[base_node.p2p.transport]
type = "socks5"
[base_node.p2p.transport.socks]
proxy_address = "/ip4/172.28.0.25/tcp/9050"
TARI_GOOD
    egress_sync_runtime_on_tor tari || exit 1
    sed 's/172\.28\.0\.25\/tcp/172.28.0.24\/tcp/' "$td/tari" >"$td/tari.wrong"
    mv "$td/tari.wrong" "$td/tari"
    ! egress_sync_runtime_on_tor tari
); then
    echo "runtime Tor endpoint attestation: PASS"
else
    echo "runtime Tor endpoint attestation: FAIL" >&2
    exit 1
fi
