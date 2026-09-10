#!/usr/bin/env bash
# Runtime diagnostics assertions for the appliance control runner (#1961/#1966).

diagnostics_doctor_verdict() { # <result-json> <healthy|nonzero>
    printf '%s' "$1" | jq -e --arg mode "$2" '
        .status == "applied" and (.doctor.exit | type == "number") and
        (if $mode == "nonzero" then .doctor.exit > 0 else .doctor.exit == 0 end) and
        (.doctor.checks | type == "array" and length > 0) and
        all(.doctor.checks[]; (.status | type == "string") and (.message | type == "string"))' >/dev/null
}

diagnostics_log_verdict() { # <result-json> <raw-wallet>
    local lines count bytes
    lines=$(printf '%s' "$1" | jq -r 'select(.status == "applied" and .container == "p2pool") | .lines // ""')
    bytes=$(LC_ALL=C printf '%s' "$lines" | wc -c | tr -d ' ')
    [ "$bytes" -le 65536 ] || return 1
    count=$(printf '%s' "$lines" | awk 'NF || NR {n=NR} END {print n+0}')
    [ "$count" -le 200 ] || return 1
    case "$lines" in *'[redacted'*) ;; *) return 1 ;; esac
    case "$lines" in *"$2"*) return 1 ;; esac
}

phase_provision_diagnostics_regressions() { # <dashboard-user> <dashboard-password>
    # dashboard_control_request reads these through Bash's dynamic scope.
    # shellcheck disable=SC2034
    local DASH_USER="$1" DASH_PASS="$2" result
    result=$(dashboard_control_request diag-doctor '{}')
    if diagnostics_doctor_verdict "$result" healthy; then
        ok "doctor returns every structured health row through the appliance control runner"
    else
        bad "doctor did not return a complete structured report through the control runner"
    fi
    result=$(dashboard_control_request diag-logs '{"container":"p2pool","lines":999}')
    if diagnostics_log_verdict "$result" "$HARNESS_WALLET"; then
        ok "p2pool log tail is host-capped and redacted through the appliance control runner"
    else
        bad "p2pool log tail missed its 200-line, 65536-byte or wallet-redaction boundary"
    fi
    result=$(dashboard_control_request diag-logs '{"container":"wallet-rpc","lines":10}')
    if printf '%s' "$result" | jq -e '.status == "rejected" and (.error | contains("not a container this dashboard may read logs for"))' >/dev/null; then
        ok "wallet service logs remain refused by the appliance host allowlist"
    else
        bad "wallet service logs crossed the appliance diagnostics allowlist"
    fi
}

phase_provision_failed_doctor_regression() { # <dashboard-user> <dashboard-password>
    # dashboard_control_request reads these through Bash's dynamic scope.
    # shellcheck disable=SC2034
    local DASH_USER="$1" DASH_PASS="$2" result
    result=$(dashboard_control_request diag-doctor '{}')
    if diagnostics_doctor_verdict "$result" nonzero; then
        ok "doctor's nonzero health report remains an applied result with every structured row"
    else
        bad "doctor's nonzero health report was lost or flattened by the appliance control runner"
    fi
}

_diagnostics_self_test() {
    local good='{"status":"applied","doctor":{"exit":2,"checks":[{"status":"fail","message":"node down"}]}}' f=0 over json
    diagnostics_doctor_verdict "$good" nonzero || f=$((f + 1))
    diagnostics_doctor_verdict "$good" healthy && f=$((f + 1))
    diagnostics_doctor_verdict '{"status":"applied","doctor":{"exit":0,"checks":[{"status":"pass","message":"healthy"}]}}' healthy || f=$((f + 1))
    diagnostics_doctor_verdict "${good/\"checks\"/\"lost\"}" nonzero && f=$((f + 1))
    diagnostics_doctor_verdict "${good/\"message\"/\"detail\"}" nonzero && f=$((f + 1))
    diagnostics_doctor_verdict "${good/\"exit\":2/\"exit\":0}" nonzero && f=$((f + 1))
    diagnostics_log_verdict '{"status":"applied","container":"p2pool","lines":"[redacted:monero-address]"}' raw-wallet-secret || f=$((f + 1))
    diagnostics_log_verdict '{"status":"applied","container":"p2pool","lines":"raw-wallet-secret"}' raw-wallet-secret && f=$((f + 1))
    over=$(awk 'BEGIN {printf "[redacted]\n"; for (i=0; i<200; i++) print "x"}')
    json=$(jq -nc --arg lines "$over" '{status:"applied",container:"p2pool",lines:$lines}')
    diagnostics_log_verdict "$json" raw-wallet-secret && f=$((f + 1))
    over=$(awk 'BEGIN {printf "[redacted]"; for (i=0; i<65536; i++) printf "x"}')
    json=$(jq -nc --arg lines "$over" '{status:"applied",container:"p2pool",lines:$lines}')
    diagnostics_log_verdict "$json" raw-wallet-secret && f=$((f + 1))
    [ "$f" -eq 0 ] || {
        printf 'appliance-diagnostics-leg self-test FAILED: %s checks\n' "$f"
        return 1
    }
    printf 'appliance-diagnostics-leg self-test passed\n'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = --self-test ]; then
    set -uo pipefail
    _diagnostics_self_test
fi
