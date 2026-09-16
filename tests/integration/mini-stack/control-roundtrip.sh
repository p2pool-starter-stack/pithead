# shellcheck shell=bash
# Dashboard -> host-runner -> masked-config payout round trip (#1959).
# Sourced by run-mini-stack.sh; reuse the tier-1 host sandbox under a host-visible temp path.

ROOT_DIR="$(cd "$HERE/../../.." && pwd)"
MINI_STACK_TMPDIR="$ROOT_DIR/data/mini-stack-tmp"
mkdir -p "$MINI_STACK_TMPDIR"
TMPDIR="$MINI_STACK_TMPDIR"
export TMPDIR MINI_STACK_TMPDIR
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/stack/lib.sh"

PAYOUT_PROBE="44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"

control_roundtrip_setup() {
    "$ROOT/scripts/build-pithead.sh" >/dev/null || return
    build_control_sandbox
    seed_control_env
    control_config mini
    (
        cd "$C" || exit
        DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null
    ) || return

    # The dashboard image runs as uid 1000. The fixture may be owned by the CI runner (or by the
    # outer test-container uid), so grant only the request-spool write/execute bits it needs.
    chmod 755 "$C/data/control" "$C/data/control/results"
    chmod 733 "$C/data/control/requests"
    export PITHEAD_ITEST_CONTROL_DIR="$C/data/control"
}

control_roundtrip_cleanup() {
    case "${SANDBOX:-}" in
    "$MINI_STACK_TMPDIR"/*) [ -d "$SANDBOX" ] && rm -rf -- "$SANDBOX" ;;
    esac
    [ -n "${MINI_STACK_TMPDIR:-}" ] && rmdir "$MINI_STACK_TMPDIR" 2>/dev/null || true
}

control_request_ready() {
    local end
    end=$(($(date +%s) + 15))
    while [ "$(date +%s)" -lt "$end" ]; do
        compgen -G "$C/data/control/requests/*.json" >/dev/null && return 0
        sleep 0.1
    done
    return 1
}

dashboard_control_request() { # <preview|commit> <json-body>; sets CONTROL_RESPONSE
    local route="$1" body="$2" pid http_rc=0 runner_rc=0
    CONTROL_RESPONSE="$SANDBOX/control-response.json"
    compose exec -T dashboard python3 - "$route" "$body" >"$CONTROL_RESPONSE" 2>/dev/null <<'PY' &
import sys
import urllib.request

route, body = sys.argv[1:]
request = urllib.request.Request(
    f"http://127.0.0.1:8000/api/control/{route}",
    data=body.encode(),
    headers={
        "Content-Type": "application/json",
        "X-Auth-User": "mini-stack-admin",
        "X-Pithead-Control": "1",
    },
)
sys.stdout.write(urllib.request.urlopen(request, timeout=40).read().decode())
PY
    pid=$!
    if control_request_ready; then
        run_pending >"$SANDBOX/control-runner.log" 2>&1 || runner_rc=$?
        # Production's root runner creates world-readable result files for the uid-1000 dashboard.
        # The CI host user can have a narrower umask, so normalize that fixture boundary explicitly.
        chmod 644 "$C/data/control/results/"*.json 2>/dev/null || true
    else
        runner_rc=1
    fi
    wait "$pid" || http_rc=$?
    [ "$http_rc" -eq 0 ] && [ "$runner_rc" -eq 0 ]
}

dashboard_config() {
    compose exec -T dashboard python3 - <<'PY'
import urllib.request

print(urllib.request.urlopen("http://127.0.0.1:8000/api/config", timeout=5).read().decode())
PY
}

assert_payout_control_roundtrip() {
    local current proposed preview id suffix commit readback
    current=$(dashboard_config 2>/dev/null) || {
        c_bad "payout approval reads the dashboard config" "GET /api/config failed"
        return
    }
    proposed=$(printf '%s' "$current" | jq --arg wallet "$PAYOUT_PROBE" '
        ._default_keys as $defaults
        | delpaths($defaults | map(split(".")))
        | del(._core_keys, ._editable_keys, ._confirm_keys, ._approval_keys, ._default_keys, ._last_apply)
        | .monero.wallet_address = $wallet') || {
        c_bad "payout approval builds a proposal" "dashboard config was not valid JSON"
        return
    }
    if ! dashboard_control_request preview "$(printf '%s' "$proposed" | jq -c '{config:.}')"; then
        c_bad "payout approval reaches the host preview" "dashboard or host runner failed"
        return
    fi
    preview=$(cat "$CONTROL_RESPONSE")
    if printf '%s' "$preview" | jq -e --arg old "$VALID_PRIMARY" --arg new "$PAYOUT_PROBE" '
        .status == "previewed" and .destructive == true and .approval_required == true and
        any(.preview_values[]; .key == "monero.wallet_address" and .old == $old and .new == $new)' >/dev/null; then
        c_ok "payout preview exposes the old/new addresses behind approval"
    else
        c_bad "payout preview exposes the old/new addresses behind approval" \
            "status=$(printf '%s' "$preview" | jq -r '.status // "missing"'), destructive=$(printf '%s' "$preview" | jq -r '.destructive // "missing"'), approval=$(printf '%s' "$preview" | jq -r '.approval_required // "missing"')"
        return
    fi

    id=$(printf '%s' "$preview" | jq -r '.id')
    suffix="${PAYOUT_PROBE: -8}"
    if ! dashboard_control_request commit "$(jq -nc --arg id "$id" --arg suffix "$suffix" \
        '{id:$id,confirm:"APPLY",approve:true,payout_suffixes:{monero:$suffix}}')"; then
        c_bad "approved payout reaches the host commit" "dashboard or host runner failed"
        return
    fi
    commit=$(cat "$CONTROL_RESPONSE")
    if printf '%s' "$commit" | jq -e '.status == "applied"' >/dev/null; then
        c_ok "typed APPLY and the exact payout suffix apply the change"
    else
        c_bad "typed APPLY and the exact payout suffix apply the change" "unexpected commit verdict"
        return
    fi

    readback=$(dashboard_config 2>/dev/null | jq -r '.monero.wallet_address')
    if [ "$readback" = "$PAYOUT_PROBE" ]; then
        c_ok "the dashboard reads the host-applied payout address back"
    else
        c_bad "the dashboard reads the host-applied payout address back" "readback did not match"
    fi
}
