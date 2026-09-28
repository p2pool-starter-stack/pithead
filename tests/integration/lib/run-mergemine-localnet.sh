# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
#
# Merge-mining acceptance leg (#2589; row V5 of #1129): a real Tari node serves P2Pool 4.18.1 its
# aux templates and accepts the blocks P2Pool submits. run-mergemine-submit.sh (V6) runs Tari's
# validator on the payload under mainnet rules; here a live node judges the whole round trip.
#
# The shipping minotari_node build runs only MainNet and StageNet, and StageNet never activates the
# coinbase-prefix payload P2Pool 4.18.1 sends. LocalNet activates it at height 0 but needs Tari's
# testnet-target build. The node is therefore Tari's published `-esme` image of the release that
# docker-compose.yml pins: the same source revision, built with TARI_TARGET_NETWORK=testnet. The leg
# prints both images' references, revisions and build targets as the recorded difference.
#
# The node runs alone on an --internal docker network, with no route out and no peers. LocalNet's
# RandomXM difficulty is fixed at 1. The throwaway P2Pool from build/p2pool (the release archive
# under test, unmodified) joins that network and mining_net, where it reads the box's monerod as the
# stack's P2Pool does. Its built-in light-mode miner runs until P2Pool reports blocks at
# MML_WANT_HEIGHTS heights. The probe then reads every reported block back from the node. Tari's
# SubmitBlock also answers OK for an orphan, so the verdicts come from the node's main chain.
# No live stack container is touched. P2Pool pays the box's configured wallets, as in V6.

# The `-esme` twin of the minotari_node pin in docker-compose.yml; the selftest keeps the versions equal.
MML_TARI_IMAGE="ghcr.io/tari-project/minotari_node:v6.0.1-pre.0-esme@sha256:7ff4e7e3884bee360110ccf6166fdb4d50718cd2299face638d4a4369253c0b0"
MML_NET=itest-mm-localnet
MML_GRPC_PORT=18142
MML_WANT_HEIGHTS=5
MML_MIN_HEIGHTS=3
MML_NODE_TIMEOUT=300
MML_MINE_TIMEOUT=900

# One value from `docker image inspect` output of the form "<revision> KEY=value ...". Pure.
_mml_fact() { # <inspect output> <env key>
    local w
    for w in $1; do
        case "$w" in "$2="*) printf '%s' "${w#*=}" && return 0 ;; esac
    done
}

# The build-target row: same revision and version as the shipping image, testnet target vs mainnet. Pure.
_mml_target_row() { # <shipping inspect output> <LocalNet inspect output>
    local sr="${1%% *}" lr="${2%% *}" st lt sv lv
    st="$(_mml_fact "$1" TARI_TARGET_NETWORK)" lt="$(_mml_fact "$2" TARI_TARGET_NETWORK)"
    sv="$(_mml_fact "$1" dockerfile_version)" lv="$(_mml_fact "$2" dockerfile_version)"
    local text="LocalNet node is the shipping release's testnet-target build: ${lv:-?} revision ${lr:-?} target ${lt:-?}; shipping ${sv:-?} revision ${sr:-?} target ${st:-?}"
    if [ -n "$sr" ] && [ "$sr" = "$lr" ] && [ -n "$sv" ] && [ "$sv" = "$lv" ] && [ "$st" = mainnet ] && [ "$lt" = testnet ]; then
        it_pass "mergemine-localnet: $text"
    else
        it_fail "mergemine-localnet: $text" "want one revision and version, built for mainnet (shipping) and testnet (LocalNet)"
    fi
}

_mml_inspect() { # <image ref>
    rx "docker image inspect -f '{{index .Config.Labels \"org.opencontainers.image.revision\"}}{{range .Config.Env}} {{.}}{{end}}' $(quote_arg "$1") 2>/dev/null" 2>/dev/null
}

_mml_ip() { # <container> <network>
    rx "docker inspect -f '{{with index .NetworkSettings.Networks \"$2\"}}{{.IPAddress}}{{end}}' $1 2>/dev/null" 2>/dev/null
}

_mml_cleanup() { # <1: also remove the shipping image this leg pulled> <shipping ref>
    rx "docker rm -f itest-mm-ln-p2pool itest-mm-ln-tari >/dev/null 2>&1; docker network rm $MML_NET >/dev/null 2>&1; docker image rm itest-mm-p2pool itest-mm-probe $(quote_arg "$MML_TARI_IMAGE") >/dev/null 2>&1" || true
    if [ "${1:-0}" = 1 ]; then rx "docker image rm $(quote_arg "$2") >/dev/null 2>&1" || true; fi
}

run_mergemine_localnet() {
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    IT_CURRENT_SCENARIO="mergemine-localnet"
    echo ""
    it_log "── merge-mining acceptance on an isolated Tari LocalNet (#2589) ────────"
    local config wallet tari_wallet ship monerod tari out rc=0 n=0 waited=0 pulled=0 up=0
    config="${BASELINE_CONFIG:-$(rx 'cat config.json' 2>/dev/null)}"
    wallet="$(printf '%s' "$config" | jq -r '.monero.wallet_address // empty' 2>/dev/null)"
    tari_wallet="$(printf '%s' "$config" | jq -r '.tari.wallet_address // empty' 2>/dev/null)"
    if [ -z "$wallet" ] || [ -z "$tari_wallet" ]; then
        it_skip_phase "mergemine-localnet (#2589)" "the box's config.json names no Monero and Tari wallet for the throwaway P2Pool" "missing"
        return 0
    fi
    ship="$(rx "grep -o 'ghcr.io/tari-project/minotari_node:[^[:space:]]*' docker-compose.yml | head -1" 2>/dev/null)"
    monerod="$(_mml_ip monerod mining_net)"
    if [ -z "$ship" ] || [ -z "$monerod" ] || ! rx "test -f tests/integration/mergemine/localnet_probe.py"; then
        it_skip_phase "mergemine-localnet (#2589)" "no probe in the target tree, no minotari_node pin in docker-compose.yml, or no running monerod on mining_net (remote Monero mode)" "missing"
        return 0
    fi

    _mml_cleanup 0
    it_log "building the LocalNet probe and P2Pool $MM_P2POOL_VERSION; pulling Tari's testnet-target image"
    if ! rx "docker build --target probe -t itest-mm-probe tests/integration/mergemine" >"$OUT_DIR/mergemine-localnet-build.log" 2>&1 ||
        ! rx "docker build -t itest-mm-p2pool --build-arg P2POOL_VERSION=$(quote_arg "$MM_P2POOL_VERSION") --build-arg P2POOL_HASH=$(quote_arg "$MM_P2POOL_HASH") build/p2pool" >>"$OUT_DIR/mergemine-localnet-build.log" 2>&1 ||
        ! rx "docker pull -q $(quote_arg "$MML_TARI_IMAGE")" >>"$OUT_DIR/mergemine-localnet-build.log" 2>&1; then
        it_fail "mergemine-localnet: probe and P2Pool $MM_P2POOL_VERSION build, Tari's LocalNet image pulls" "see $OUT_DIR/mergemine-localnet-build.log"
        _mml_cleanup 0
        return 0
    fi
    rx "docker image inspect $(quote_arg "$ship") >/dev/null 2>&1" || pulled=1
    [ "$pulled" = 0 ] || rx "docker pull -q $(quote_arg "$ship")" >>"$OUT_DIR/mergemine-localnet-build.log" 2>&1 || true
    it_log "mergemine-localnet shipping image: $ship"
    it_log "mergemine-localnet LocalNet image: $MML_TARI_IMAGE"
    it_log "mergemine-localnet P2Pool: $(rx "docker run --rm --entrypoint p2pool itest-mm-p2pool --version 2>&1 | head -1") (archive sha256 $MM_P2POOL_HASH)"
    _mml_target_row "$(_mml_inspect "$ship")" "$(_mml_inspect "$MML_TARI_IMAGE")"

    if ! rx "docker network create --internal $MML_NET >/dev/null && docker run -d --name itest-mm-ln-tari --network $MML_NET --entrypoint minotari_node $(quote_arg "$MML_TARI_IMAGE") --network localnet --non-interactive-mode --disable-splash-screen --base-path /tmp/localnet --config /tmp/localnet/config.toml --mining-enabled --second-layer-grpc-enabled --grpc-address /ip4/0.0.0.0/tcp/$MML_GRPC_PORT -p base_node.p2p.transport.type=tcp -p base_node.p2p.transport.tcp.listener_address=/ip4/0.0.0.0/tcp/18189 >/dev/null"; then
        it_fail "mergemine-localnet: LocalNet Tari node started on an internal network" "docker network create or run failed"
        _mml_cleanup "$pulled" "$ship"
        return 0
    fi
    tari="$(_mml_ip itest-mm-ln-tari "$MML_NET")"
    while [ -n "$tari" ] && [ "$waited" -lt "$MML_NODE_TIMEOUT" ]; do
        if out="$(rx "docker run --rm --network $MML_NET itest-mm-probe python3 /usr/local/bin/localnet_probe.py tip $tari:$MML_GRPC_PORT" 2>/dev/null)"; then
            up=1 && break
        fi
        sleep 5
        waited=$((waited + 5))
    done
    rx "docker logs itest-mm-ln-tari 2>&1 | tail -n 300" 2>/dev/null | redact >"$OUT_DIR/mergemine-localnet-tari.log"
    if [ "$up" != 1 ]; then
        it_fail "mergemine-localnet: LocalNet Tari node answered gRPC within ${MML_NODE_TIMEOUT}s" "see $OUT_DIR/mergemine-localnet-tari.log"
        _mml_cleanup "$pulled" "$ship"
        return 0
    fi
    it_log "mergemine-localnet ${out#INFO }"
    assert_eq "mergemine-localnet: the LocalNet node's only network is internal (no route out, no peers)" \
        "$(rx "docker network inspect -f '{{.Internal}}' $MML_NET; docker inspect -f '{{len .NetworkSettings.Networks}}' itest-mm-ln-tari" 2>/dev/null | tr '\n' ' ')" "true 1 "

    if ! rx "u=\$(sed -n 's/^MONERO_NODE_USERNAME=//p' .env 2>/dev/null); p=\$(sed -n 's/^MONERO_NODE_PASSWORD=//p' .env 2>/dev/null); login=(); [ -z \"\$u\" ] || login=(--rpc-login \"\$u:\$p\"); docker create --name itest-mm-ln-p2pool --network mining_net itest-mm-p2pool --host $monerod --rpc-port 18081 --zmq-port 18083 \"\${login[@]}\" --wallet $(quote_arg "$wallet") --merge-mine tari://$tari:$MML_GRPC_PORT $(quote_arg "$tari_wallet") --stratum 127.0.0.1:43333 --p2p 127.0.0.1:47889 --no-dns --no-upnp --no-igd --no-cache --no-color --light-mode --start-mining 1 --loglevel 4 >/dev/null && docker network connect $MML_NET itest-mm-ln-p2pool && docker start itest-mm-ln-p2pool >/dev/null"; then
        it_fail "mergemine-localnet: throwaway P2Pool started on mining_net and the LocalNet network" "docker create, network connect or start failed"
        _mml_cleanup "$pulled" "$ship"
        return 0
    fi
    waited=0
    while [ "$waited" -lt "$MML_MINE_TIMEOUT" ]; do
        n="$(rx "docker logs itest-mm-ln-p2pool 2>&1 | sed -n 's/.*Mined Tari block [0-9a-f]* at height \\([0-9]*\\).*/\\1/p' | sort -u | wc -l" 2>/dev/null)" || n=0
        [ "${n:-0}" -ge "$MML_WANT_HEIGHTS" ] && break
        sleep 10
        waited=$((waited + 10))
    done
    rx "docker stop -t 10 itest-mm-ln-p2pool >/dev/null 2>&1" || true
    it_log "mergemine-localnet P2Pool reported Tari blocks at ${n:-0} heights in ${waited}s"
    rx "docker logs itest-mm-ln-p2pool 2>&1 | tail -n 400" 2>/dev/null | redact >"$OUT_DIR/mergemine-localnet-p2pool.log"

    out="$(rx "docker logs itest-mm-ln-p2pool 2>&1 | grep -E 'uses chain_id|Tari aux block template|Mined Tari block|SubmitBlock failed' | docker run --rm -i --network $MML_NET itest-mm-probe python3 /usr/local/bin/localnet_probe.py judge $tari:$MML_GRPC_PORT $MML_MIN_HEIGHTS" 2>&1)" || rc=$?
    printf '%s\n' "$out" | redact >"$OUT_DIR/mergemine-localnet-judge.log"
    _mm_rows mergemine-localnet "$out"
    [ "$rc" -eq 0 ] || it_log "mergemine-localnet probe exit $rc (see $OUT_DIR/mergemine-localnet-judge.log)"
    _mml_cleanup "$pulled" "$ship"
}
