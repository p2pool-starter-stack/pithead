# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

rotation_with_receipts() {
    local receipts rc=0
    receipts=$(rx "set -o pipefail
        $IT_PITHEAD rotate-dashboard-onion -y 2>&1 >/dev/null |
            python3 tests/integration/tools/tor-lifecycle-receipts.py collect
        exit \${PIPESTATUS[0]}") || rc=$?
    mkdir -p "$OUT_DIR/tor-lifecycle" &&
        printf '%s\n' "$receipts" >"$OUT_DIR/tor-lifecycle/rotation.jsonl" ||
        it_fail "rotation receipts retained" "receipt artifact could not be written"
    return "$rc"
}

healer_with_receipts() {
    local receipts rc=0
    receipts=$(rx "set -o pipefail
        docker exec -i dashboard python3 - 2>&1 |
            python3 tests/integration/tools/tor-lifecycle-receipts.py collect
        exit \${PIPESTATUS[0]}" --stdin <"$HERE/tools/tor-lifecycle-healer.py") || rc=$?
    assert_rc "Tor healer receipt fixture completes" "$rc" 0
    mkdir -p "$OUT_DIR/tor-lifecycle" &&
        printf '%s\n' "$receipts" >"$OUT_DIR/tor-lifecycle/healer.jsonl" ||
        it_fail "healer receipts retained" "receipt artifact could not be written"
    python3 "$HERE/tools/tor-lifecycle-receipts.py" \
        "$OUT_DIR/tor-lifecycle/rotation.jsonl" "$OUT_DIR/tor-lifecycle/healer.jsonl" >/dev/null 2>&1
    assert_rc "Tor lifecycle receipts identify both callers and failed calls" "$?" 0
    wait_status_ok 240
    assert_rc "stack healthy after healer receipt fixture" "$?" 0
}
