# shellcheck shell=bash
appliance_engine_contract_leg() {
    local stage baseline payload out rc=0
    stage=$(mktemp -d) || {
        bad "engine contract could not allocate staging"
        return 1
    }
    if baseline=$(git -C "$SCRIPT_DIR/../.." rev-parse '723b1d7^{commit}') &&
        git -C "$SCRIPT_DIR/../.." archive "$baseline" lib/pithead | tar -x -C "$stage" &&
        python3 "$SCRIPT_DIR/engine-contract.py" extract "$stage/lib/pithead" >"$stage/rc3.json" &&
        python3 "$SCRIPT_DIR/engine-contract.py" extract "$SCRIPT_DIR/../../lib/pithead" >"$stage/current.json" &&
        cp "$SCRIPT_DIR/engine-contract.py" "$SCRIPT_DIR/engine-contract-guest.sh" \
            "$SCRIPT_DIR/engine-contract-predicate.sh" "$SCRIPT_DIR/container-restart-leg.sh" "$stage/" &&
        cp "$SCRIPT_DIR/../integration/lib/readiness-churn.sh" "$stage/readiness-churn.sh" &&
        sed -n '/^_pred_status_ok() /p' "$SCRIPT_DIR/../integration/lib.sh" >"$stage/status-predicate.sh" &&
        [ -s "$stage/status-predicate.sh" ] &&
        rm -rf "${stage:?}/lib" &&
        payload=$(tar -czf - -C "$stage" . | base64 | tr -d '\n'); then
        :
    else
        bad "engine contract could not stage required source forms and predicates"
        rm -rf "$stage"
        return 1
    fi
    out="$stage/result"
    SSH_TIMEOUT=600 _ssh "exec 2>&1; set -e; export TMPDIR=\${TMPDIR:-/data/tmp}; mkdir -p \"\$TMPDIR\"; d=\$(mktemp -d); trap 'rm -rf \"\$d\"' EXIT; printf %s '$payload' | base64 -d | tar -xzf - -C \"\$d\"; bash \"\$d/engine-contract-guest.sh\"" >"$out" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] && grep -Fq 'appliance engine contract: PASS' "$out"; then
        ok "all CLI engine forms pass on running/stopped appliance containers; original census RED and churn detected (#3403)"
    else
        [ "$rc" -ne 0 ] || rc=1
        bad "appliance engine contract failed (#3403, exit $rc)"
        tail -20 "$out"
        [ ! -s "${SSH_ERR:-}" ] || tail -20 "$SSH_ERR"
    fi
    rm -rf "$stage"
    return "$rc"
}
