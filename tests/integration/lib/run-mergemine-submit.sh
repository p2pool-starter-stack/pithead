# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
#
# Merge-mining submission leg (#2586; row V6 of #1129): P2Pool's actual Tari serializer against
# Tari's actual validator on both sides of the mainnet 350,000 fork. mergemine-probe.sh proves a
# startup chain_id only; the fake-daemon mini-stack never reaches merge mining (#1397).
#
# A throwaway P2Pool, built from build/p2pool/Dockerfile with the release archive under test, runs
# with no peers on host loopback ports against the bench's own monerod (read-only use: templates and
# ZMQ), mining with its built-in light-mode miner. Its Tari node is tests/integration/mergemine's
# recording fake, serving Tari-generated mainnet templates at heights 349,999, 350,000 and 350,001
# at a test difficulty. The fixture, compiled inside Tari's workspace at the pinned tag, then runs
# Tari's monero_randomx_difficulty on each captured submission and on two controls built from the
# same Monero block: the pre-fork Keccak-state payload and a one-bit-mutated prefix.
#
# Expected verdicts follow Tari's height rule, not a wish: below 350,000 only the legacy format
# decodes, so P2Pool 4.18.1's payload must be rejected there and the legacy one accepted; from
# 350,000 the reverse, and the mutated prefix is rejected too. The one test-only deviation is the
# difficulty: achieved work is compared with the test target, not mainnet's (both printed).
# Nothing is submitted to Tari mainnet; the fake records and answers nothing. The throwaway P2Pool
# pays the bench's own configured wallets, so no payout address changes.

MM_P2POOL_VERSION="${IT_MM_P2POOL_VERSION:-v4.18.1}"
MM_P2POOL_HASH="${IT_MM_P2POOL_HASH:-eeab5aca0edf4756cb295c5fda5b2d5344208aecbbdcb2ffd8471dfe14e6c2c5}"
MM_DIFFICULTY=200
MM_CAPTURE_TIMEOUT=1200
MM_WANT_SUBMISSIONS=6 # two full cycles of the three templates
MM_TARI_PORT=48142

# Turn `ROW PASS|FAIL <text>` / `INFO <text>` lines (the fixture's here, the LocalNet probe's in
# run-mergemine-localnet.sh) into verdicts. Pure, for the selftests.
_mm_rows() { # <phase> <output>
    local line rows=0
    while IFS= read -r line; do
        case "$line" in
        "ROW PASS "*) it_pass "$1: ${line#ROW PASS }" && rows=$((rows + 1)) ;;
        "ROW FAIL "*) it_fail "$1: ${line#ROW FAIL }" && rows=$((rows + 1)) ;;
        "INFO "*) it_log "$1 ${line#INFO }" ;;
        esac
    done <<<"$2"
    [ "$rows" -gt 0 ] || it_fail "$1: the checker printed its rows" "no ROW lines in its output"
}

_mm_cleanup() { # <work dir>
    rx "docker rm -f itest-mm-p2pool itest-mm-tari >/dev/null 2>&1; docker image rm itest-mm-p2pool >/dev/null 2>&1; rm -rf $(quote_arg "$1")" || true
}

run_mergemine_submit() {
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    IT_CURRENT_SCENARIO="mergemine-submit"
    echo ""
    it_log "── merge-mining submission across the Tari 350,000 fork (#2586) ────────"
    local config wallet tari_wallet work n=0 waited=0 out rc
    config="${BASELINE_CONFIG:-$(rx 'cat config.json' 2>/dev/null)}"
    wallet="$(printf '%s' "$config" | jq -r '.monero.wallet_address // empty' 2>/dev/null)"
    tari_wallet="$(printf '%s' "$config" | jq -r '.tari.wallet_address // empty' 2>/dev/null)"
    if [ -z "$wallet" ] || [ -z "$tari_wallet" ]; then
        it_skip_phase "mergemine-submit (#2586)" "the box's config.json names no Monero and Tari wallet for the throwaway P2Pool" "missing"
        return 0
    fi
    if ! rx "test -f tests/integration/mergemine/Dockerfile && curl -s -o /dev/null --max-time 10 http://127.0.0.1:18081/get_info"; then
        it_skip_phase "mergemine-submit (#2586)" "no fixture in the target tree, or no monerod RPC on the box's loopback (remote Monero mode)" "missing"
        return 0
    fi

    it_log "building the fixture (Tari validator; a cold build takes 30-60 min) and P2Pool $MM_P2POOL_VERSION"
    if ! rx "docker build -t itest-mm-fixture tests/integration/mergemine" >"$OUT_DIR/mergemine-fixture-build.log" 2>&1; then
        it_fail "mergemine-submit: the Tari validator fixture builds" "see $OUT_DIR/mergemine-fixture-build.log"
        return 0
    fi
    if ! rx "docker build -t itest-mm-p2pool --build-arg P2POOL_VERSION=$(quote_arg "$MM_P2POOL_VERSION") --build-arg P2POOL_HASH=$(quote_arg "$MM_P2POOL_HASH") build/p2pool" >"$OUT_DIR/mergemine-p2pool-build.log" 2>&1; then
        it_fail "mergemine-submit: P2Pool $MM_P2POOL_VERSION builds from build/p2pool with its archive hash" "see $OUT_DIR/mergemine-p2pool-build.log"
        return 0
    fi
    it_log "mergemine-submit P2Pool: $(rx "docker run --rm --entrypoint p2pool itest-mm-p2pool --version 2>&1 | head -1") (archive sha256 $MM_P2POOL_HASH)"

    work="$(rx 'mktemp -d /tmp/itest-mm.XXXXXX')" || {
        it_fail "mergemine-submit: work dir on the box" "mktemp failed"
        return 0
    }
    if ! rx "docker run --rm -v $(quote_arg "$work"):/work itest-mm-fixture p2pool_mm_fixture templates /work $MM_DIFFICULTY" >"$OUT_DIR/mergemine-templates.log" 2>&1 ||
        ! rx "docker run -d --name itest-mm-tari --network host -v $(quote_arg "$work"):/work itest-mm-fixture python3 /usr/local/bin/fake_tari_node.py $MM_TARI_PORT /work" >/dev/null ||
        ! rx "u=\$(sed -n 's/^MONERO_NODE_USERNAME=//p' .env 2>/dev/null); p=\$(sed -n 's/^MONERO_NODE_PASSWORD=//p' .env 2>/dev/null); login=(); [ -z \"\$u\" ] || login=(--rpc-login \"\$u:\$p\"); docker run -d --name itest-mm-p2pool --network host itest-mm-p2pool --host 127.0.0.1 --rpc-port 18081 --zmq-port 18083 \"\${login[@]}\" --wallet $(quote_arg "$wallet") --merge-mine tari://127.0.0.1:$MM_TARI_PORT $(quote_arg "$tari_wallet") --stratum 127.0.0.1:43333 --p2p 127.0.0.1:47889 --no-dns --no-upnp --no-igd --no-cache --light-mode --start-mining 2 --loglevel 3" >/dev/null; then
        it_fail "mergemine-submit: fixture templates, recording Tari node and throwaway P2Pool started" "see $OUT_DIR/mergemine-templates.log"
        _mm_cleanup "$work"
        return 0
    fi
    sed -n 's/^INFO /mergemine-submit /p' "$OUT_DIR/mergemine-templates.log" | while IFS= read -r l; do it_log "$l"; done

    while [ "$waited" -lt "$MM_CAPTURE_TIMEOUT" ]; do
        n="$(rx "ls $(quote_arg "$work") | grep -c '^submit-'" 2>/dev/null)" || n=0
        [ "${n:-0}" -ge "$MM_WANT_SUBMISSIONS" ] && break
        sleep 10
        waited=$((waited + 10))
    done
    rx "docker logs itest-mm-p2pool 2>&1 | tail -n 400" 2>/dev/null | redact >"$OUT_DIR/mergemine-p2pool.log"
    rx "docker rm -f itest-mm-p2pool itest-mm-tari >/dev/null 2>&1" || true
    if [ "${n:-0}" -lt "$MM_WANT_SUBMISSIONS" ]; then
        it_fail "mergemine-submit: P2Pool submitted $MM_WANT_SUBMISSIONS Tari solutions within ${MM_CAPTURE_TIMEOUT}s" "got ${n:-0}; see $OUT_DIR/mergemine-p2pool.log"
    fi

    rc=0
    out="$(rx "docker run --rm -v $(quote_arg "$work"):/work itest-mm-fixture p2pool_mm_fixture validate /work $MM_DIFFICULTY" 2>&1)" || rc=$?
    printf '%s\n' "$out" | redact >"$OUT_DIR/mergemine-validate.log"
    _mm_rows mergemine-submit "$out"
    [ "$rc" -eq 0 ] || it_log "mergemine-submit validator exit $rc (see $OUT_DIR/mergemine-validate.log)"
    _mm_cleanup "$work"
}
