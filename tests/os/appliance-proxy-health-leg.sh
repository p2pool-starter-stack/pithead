#!/usr/bin/env bash
phase_provision_proxy_health() {
    local payload out rc=0 line
    payload=$({
        printf 'UNIT_FILTER_B64=%s\n' "$(base64 <"$SCRIPT_DIR/proxy-quadlet-unit.awk" | tr -d '\n')"
        cat "$SCRIPT_DIR/proxy-quadlet-proof.sh"
    } | base64 | tr -d '\n')
    out=$(mktemp)
    SSH_TIMEOUT=300 _ssh "bash -c \"\$(printf %s '$payload' | base64 -d)\" </dev/null 2>&1" >"$out" 2>&1 </dev/null || rc=$?
    if [ "$rc" -ne 0 ] && [ -s "${SSH_ERR:-/dev/null}" ]; then
        printf '\nSSH transport diagnostics:\n' >>"$out"
        head -c 4096 "$SSH_ERR" >>"$out"
    fi
    while IFS= read -r line; do
        case "$line" in PASS:*) ok "${line#PASS: } (#1217)" ;; esac
    done <"$out"
    if [ "$rc" -ne 0 ] || ! grep -qxF 'PASS: native Quadlet proxy health proof complete' "$out"; then
        bad "native Quadlet proxy health proof did not complete (exit $rc, #1217)"
        bash "$SCRIPT_DIR/../../scripts/sanitize-test-log.sh" --lines 40 "$out"
    fi
    rm -f "$out"
}
