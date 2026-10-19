# shellcheck shell=bash
# Capture the asserted invocation before backup/restore can replace the failing state.
assert_node_recovery_status() {
    local started elapsed wait_rc=0 status_rc capture_rc script name
    started="$(now_s)"
    wait_status_ok 240 || wait_rc=$?
    elapsed=$(($(now_s) - started))
    # Reuse the existing transport without exporting credentials.
    script="$(declare -f rx quote_arg)"
    for name in IT_MODE IT_REMOTE_DIR IT_PITHEAD IT_SSH_DEST IT_SSH_OPTS; do
        if declare -p "$name" >/dev/null 2>&1; then
            script="$script
$(declare -p "$name")"
        fi
    done
    status_rc="$(python3 "${BASH_SOURCE[0]%/*}/node_recovery_evidence.py" \
        "$script" "$IT_PITHEAD status" "$OUT_DIR/node-recovery.failure.json" "$wait_rc" "$elapsed")"
    capture_rc=$?
    if [ "$capture_rc" -ne 0 ]; then
        it_fail "node recovery failure evidence captured" "capture unavailable; original status verdict retained when readable"
    fi
    assert_rc "status OK after node recovery" "${status_rc:-unavailable}" "0"
}
