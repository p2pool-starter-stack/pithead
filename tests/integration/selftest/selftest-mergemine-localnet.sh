#!/usr/bin/env bash
#
# Self-test for the merge-mining acceptance leg (run-mergemine-localnet.sh, #2589), driven against a
# stubbed `rx`, with no bench and no docker. Pins: (1) the probe's protobuf reading and verdicts
# (tests/integration/mergemine/test_localnet_probe.py); (2) the LocalNet image is the `-esme` twin
# of the minotari_node release docker-compose.yml pins, by digest; (3) the build-target row passes
# only for one revision and version built for mainnet and testnet; (4) a box without both wallets
# or without a local monerod skips as missing; (5) a node that never answers fails and cleans up;
# (6) the leg never drives the live stack, keeps the node on the internal network alone, points
# P2Pool at the LocalNet node, maps the probe's rows, and removes only what it pulled.
#
# Standalone (not sourced by selftest.sh), same reasoning as the other run-*.sh self-tests.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-mergemine-submit.sh
source "$HERE/../lib/run-mergemine-submit.sh"
# shellcheck source=tests/integration/lib/run-mergemine-localnet.sh
source "$HERE/../lib/run-mergemine-localnet.sh"

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT
RX_LOG="$OUT_DIR/rx.log"
SHIP="ghcr.io/tari-project/minotari_node:v6.0.1-pre.0-mainnet@sha256:23ce"
SHIP_FACTS="80a52117 PATH=/bin dockerfile_version=v6.0.1-pre.0 TARI_NETWORK=mainnet TARI_TARGET_NETWORK=mainnet"
LN_FACTS="80a52117 PATH=/bin dockerfile_version=v6.0.1-pre.0 TARI_NETWORK=esme TARI_TARGET_NETWORK=testnet"
STUB_MONEROD=198.51.100.26 STUB_NODE_UP=1 STUB_SHIP_INSPECT_RC=1 STUB_JUDGE=""
rx() {
    printf '%s\n' "$1" >>"$RX_LOG"
    case "$1" in
    *"grep -o 'ghcr.io/tari-project/minotari_node"*) echo "$SHIP" ;;
    *'Networks "mining_net"'*) echo "$STUB_MONEROD" ;;
    *'Networks "itest-mm-localnet"'*) echo 192.0.2.2 ;;
    *"docker image inspect -f"*esme*) echo "$LN_FACTS" ;;
    *"docker image inspect -f"*) echo "$SHIP_FACTS" ;;
    *"docker image inspect "*) return "$STUB_SHIP_INSPECT_RC" ;;
    *"localnet_probe.py tip"*) [ "$STUB_NODE_UP" = 1 ] && echo "INFO LocalNet tip height=0 hash=00" ;;
    *"{{.Internal}}"*) printf 'true\n1\n' ;;
    *"Mined Tari block"*"sort -u"*) echo 5 ;;
    *"localnet_probe.py judge"*) printf '%s\n' "$STUB_JUDGE" ;;
    *) : ;;
    esac
}
sleep() { :; }

reset() {
    IT_PASS=0 IT_FAIL=0 IT_FAILED_NAMES=""
    IT_SKIPPED=0 IT_SKIPPED_PHASES=0 IT_SKIPPED_MISSING=0 IT_SKIPPED_NAMES=""
    : >"$RX_LOG"
}
T_PASS=0 T_FAIL=0
check() { if [ "$2" = "$3" ]; then T_PASS=$((T_PASS + 1)); else T_FAIL=$((T_FAIL + 1)) && echo "FAIL: $1 (got [$2], want [$3])"; fi; }

echo "== probe: protobuf reading and verdicts =="
if python3 -m unittest -q "$ROOT/tests/integration/mergemine/test_localnet_probe.py" >"$OUT_DIR/unittest.log" 2>&1; then
    check "probe unit tests pass" ok ok
else
    cat "$OUT_DIR/unittest.log"
    check "probe unit tests pass" failed ok
fi

echo "== the LocalNet image is the -esme twin of the pinned release, by digest =="
shipped="$(grep -o 'ghcr.io/tari-project/minotari_node:v[^@-]*\(-pre\.[0-9]*\)\?-mainnet@sha256:[0-9a-f]\{64\}' "$ROOT/docker-compose.yml" | head -1)"
check "docker-compose.yml pins minotari_node by digest" "$([ -n "$shipped" ] && echo yes)" yes
ship_version="${shipped#*:}" ship_version="${ship_version%-mainnet@*}"
ln_version="${MML_TARI_IMAGE#*:}" ln_version="${ln_version%-esme@*}"
check "LocalNet image is the same release as the shipping pin" "$ln_version" "$ship_version"
check "LocalNet image is pinned by digest" "$([[ "$MML_TARI_IMAGE" =~ -esme@sha256:[0-9a-f]{64}$ ]] && echo yes)" yes

echo "== build-target row =="
reset
_mml_target_row "$SHIP_FACTS" "$LN_FACTS" >/dev/null 2>&1
check "same revision, mainnet vs testnet passes" "$IT_PASS/$IT_FAIL" 1/0
reset
_mml_target_row "$SHIP_FACTS" "${LN_FACTS/80a52117/97aa59ec}" >/dev/null 2>&1
check "a different revision fails" "$IT_FAIL" 1
reset
_mml_target_row "$SHIP_FACTS" "$SHIP_FACTS" >/dev/null 2>&1
check "a mainnet-target LocalNet image fails" "$IT_FAIL" 1
reset
_mml_target_row "" "" >/dev/null 2>&1
check "no inspect output fails" "$IT_FAIL" 1

echo "== no Tari wallet in config.json: skipped as missing, nothing built =="
reset
BASELINE_CONFIG='{"monero":{"wallet_address":"4xyz"},"tari":{}}'
run_mergemine_localnet >/dev/null 2>&1
check "missing wallet skips the phase" "$IT_SKIPPED_PHASES" 1
check "missing wallet is not a failure" "$IT_FAIL" 0
check "missing wallet builds nothing" "$(grep -c 'docker build' "$RX_LOG")" 0

echo "== no monerod on mining_net (remote Monero): skipped as missing =="
reset
BASELINE_CONFIG='{"monero":{"wallet_address":"4xyz"},"tari":{"wallet_address":"12abc"}}'
STUB_MONEROD=""
run_mergemine_localnet >/dev/null 2>&1
check "remote Monero skips the phase" "$IT_SKIPPED_PHASES/$IT_FAIL" 1/0
check "remote Monero builds nothing" "$(grep -c 'docker build' "$RX_LOG")" 0
STUB_MONEROD=198.51.100.26

echo "== node never answers: fails, P2Pool never starts, everything cleaned up =="
reset
STUB_NODE_UP=0
run_mergemine_localnet >/dev/null 2>&1
check "silent node fails once (build-target row passes)" "$IT_PASS/$IT_FAIL" 1/1
check "P2Pool not started" "$(grep -c 'docker create --name itest-mm-ln-p2pool' "$RX_LOG")" 0
check "network and containers removed" "$(grep -c "docker network rm $MML_NET" "$RX_LOG")" 2
STUB_NODE_UP=1

echo "== full round trip: rows mapped, node isolated, live stack untouched =="
reset
STUB_JUDGE=$'INFO accepted height=1\nROW PASS templates\nROW PASS accepted\nROW FAIL linked'
run_mergemine_localnet >/dev/null 2>&1
check "target row, isolation row and two probe passes" "$IT_PASS" 4
check "one probe failure" "$IT_FAIL" 1
check "node network is internal" "$(grep -c "docker network create --internal $MML_NET" "$RX_LOG")" 1
check "node runs LocalNet from the pinned -esme image" "$(grep -F -- "--network $MML_NET --entrypoint minotari_node $(quote_arg "$MML_TARI_IMAGE") --network localnet" "$RX_LOG" | grep -c -- '--mining-enabled --second-layer-grpc-enabled')" 1
check "P2Pool reads monerod on mining_net" "$(grep -c -- '--network mining_net itest-mm-p2pool --host 198.51.100.26 ' "$RX_LOG")" 1
check "P2Pool dials the LocalNet node" "$(grep -c -- '--merge-mine tari://192.0.2.2:18142' "$RX_LOG")" 1
check "P2Pool joins the LocalNet network" "$(grep -c "docker network connect $MML_NET itest-mm-ln-p2pool" "$RX_LOG")" 1
check "probe judges on the LocalNet network" "$(grep -c "network $MML_NET itest-mm-probe python3 /usr/local/bin/localnet_probe.py judge 192.0.2.2:18142 $MML_MIN_HEIGHTS" "$RX_LOG")" 1
check "no compose or pithead CLI call" "$(grep -cE 'docker compose|docker-compose |pithead ' "$RX_LOG")" 0
check "only itest-mm containers are named" "$(grep -oE -- '--name [a-z-]+' "$RX_LOG" | grep -vc 'itest-mm-')" 0
check "shipping image pulled because absent" "$(grep -c "docker pull -q $(quote_arg "$SHIP")" "$RX_LOG")" 1
check "shipping image removed because pulled" "$(grep -c "docker image rm $(quote_arg "$SHIP")" "$RX_LOG")" 1

echo "== a shipping image already on the box stays =="
reset
rx() {
    printf '%s\n' "$1" >>"$RX_LOG"
    case "$1" in
    *"grep -o 'ghcr.io/tari-project/minotari_node"*) echo "$SHIP" ;;
    *'Networks "mining_net"'*) echo "$STUB_MONEROD" ;;
    *"docker image inspect -f"*) echo "$SHIP_FACTS" ;;
    *) : ;;
    esac
}
run_mergemine_localnet >/dev/null 2>&1
check "present shipping image not pulled" "$(grep -c "docker pull -q $(quote_arg "$SHIP")" "$RX_LOG")" 0
check "present shipping image not removed" "$(grep -c "docker image rm $(quote_arg "$SHIP")" "$RX_LOG")" 0

echo "selftest-mergemine-localnet: $T_PASS passed, $T_FAIL failed"
[ "$T_FAIL" -eq 0 ]
