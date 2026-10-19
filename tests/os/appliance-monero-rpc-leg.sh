#!/usr/bin/env bash
# The guest fixture leaves the existing nodes and Tor state untouched; cleanup owns only
# its scratch directory and native proof unit, even when an assertion fails.
phase_provision_monero_rpc() {
    local payload out rc=0 line
    payload=$({
        printf 'P2P_PROBE_B64=%s\n' "$(base64 <"$SCRIPT_DIR/../integration/monero-p2p-rpc-port.py" | tr -d '\n')"
        printf 'UNIT_FILTER_B64=%s\n' "$(base64 <"$SCRIPT_DIR/monero-quadlet-unit.awk" | tr -d '\n')"
        cat "$SCRIPT_DIR/monero-quadlet-proof.sh"
    } | base64 | tr -d '\n')
    out=$(mktemp)
    SSH_TIMEOUT=600 _ssh "printf %s '$payload' | base64 -d | bash" >"$out" 2>&1 || rc=$?
    while IFS= read -r line; do
        case "$line" in PASS:*) ok "${line#PASS: } (#2921)" ;; esac
    done <"$out"
    if [ "$rc" -ne 0 ] || ! grep -qxF 'PASS: native Quadlet RPC proof complete' "$out"; then
        bad "native Quadlet Monero RPC proof did not complete (exit $rc, #2921)"
        bash "$SCRIPT_DIR/../../scripts/sanitize-test-log.sh" --lines 40 "$out"
    fi
    rm -f "$out"
}
