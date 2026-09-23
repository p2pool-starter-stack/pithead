#!/usr/bin/env bash
#
# Self-test for the merge-mining submission leg (run-mergemine-submit.sh, #2586), driven against a
# stubbed `rx` — no bench, no docker. Pins: (1) the fixture's ROW lines become verdicts one for
# one, and output with no ROW line is a failure, never a silent pass; (2) a box without both
# wallets skips the phase in the "missing" class; (3) a capture that never arrives fails and the
# validator still runs; (4) the leg never drives the live stack (no compose, no pithead CLI, only
# itest-mm-* containers) and points P2Pool at the recording node, not the bench's Tari.
#
# Standalone (not sourced by selftest.sh), same reasoning as the other run-*.sh self-tests.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-mergemine-submit.sh
source "$HERE/../lib/run-mergemine-submit.sh"

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT
RX_LOG="$OUT_DIR/rx.log"
STUB_VALIDATE=""
rx() {
    printf '%s\n' "$1" >>"$RX_LOG"
    case "$1" in
    *"validate /work"*) printf '%s\n' "$STUB_VALIDATE" ;;
    *mktemp*) echo /tmp/itest-mm.test ;;
    *"grep -c"*) echo 0 ;;
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

# 1. ROW lines map one for one; INFO lines are not verdicts.
reset
_mm_rows $'INFO height=350000\nROW PASS 350000: accepted\nROW FAIL 350000: legacy ACCEPTED\nROW PASS 350001: rejected' >/dev/null 2>&1
p=$IT_PASS f=$IT_FAIL
check "two ROW PASS lines pass" "$p" 2
check "one ROW FAIL line fails" "$f" 1

# 2. No ROW line at all is a failure.
reset
_mm_rows $'error: something\nINFO only' >/dev/null 2>&1
check "output without ROW lines fails once" "$IT_FAIL" 1

# 3. No Tari wallet in the box's config: phase skipped as missing, no docker work.
reset
BASELINE_CONFIG='{"monero":{"wallet_address":"4xyz"},"tari":{}}'
run_mergemine_submit >/dev/null 2>&1
check "missing wallet skips the phase" "$IT_SKIPPED_PHASES" 1
check "missing wallet is not a failure" "$IT_FAIL" 0
check "missing wallet builds nothing" "$(grep -c 'docker build' "$RX_LOG")" 0

# 4. Full path with a capture that never arrives and a validator that passes its rows.
reset
BASELINE_CONFIG='{"monero":{"wallet_address":"4xyz"},"tari":{"wallet_address":"12abc"}}'
MM_CAPTURE_TIMEOUT=0
STUB_VALIDATE=$'ROW PASS 349999: rejected\nROW PASS 350000: accepted'
run_mergemine_submit >/dev/null 2>&1
check "missing submissions fail once" "$IT_FAIL" 1
check "validator rows still counted" "$IT_PASS" 2
check "P2Pool dials the recording node" "$(grep -c -- '--merge-mine tari://127.0.0.1:48142' "$RX_LOG")" 1
check "no compose or pithead CLI call" "$(grep -cE 'docker compose|docker-compose|pithead ' "$RX_LOG")" 0
check "only itest-mm containers are named" "$(grep -oE -- '--name [a-z-]+' "$RX_LOG" | grep -vc 'itest-mm-')" 0
check "work dir and containers cleaned up" "$(grep -c 'docker rm -f itest-mm-p2pool itest-mm-tari' "$RX_LOG")" 2

echo "selftest-mergemine-submit: $T_PASS passed, $T_FAIL failed"
[ "$T_FAIL" -eq 0 ]
