#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329,SC2030,SC2031,SC1091
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
echo "== post-operation user-visible health invariants (#3402) =="

SNAP_OK=$'caddy c1 0 t1 true healthy\ndashboard d1 0 t2 true healthy\nxmrig-proxy x1 0 t3 true none'

drive() ( # <fault> -> failing row labels, one per line
    local fault="$1"
    IT_FAIL=0 IT_PASS=0
    failed=""
    POI_STABLE_S=0
    it_pass() { :; }
    it_fail() { printf '%s\n' "$1"; }
    sleep() { :; }
    wait_for() {
        shift 3
        "$@"
    }
    rx() {
        case "$1" in
        *'/api/access'*) [ "$fault" = failures ] && printf '{"failures_24h": 3}' || printf '{"failures_24h": 0}' ;;
        *'docker ps -q'*)
            local snap="$SNAP_OK"
            if [ -e "$OUT/second" ]; then
                case "$fault" in
                restart) snap=${snap/caddy c1 0/caddy c1 1} ;;
                recreate) snap=${snap/caddy c1/caddy c2} ;;
                unhealthy) snap=${snap/dashboard d1 0 t2 true healthy/dashboard d1 0 t2 true starting} ;;
                gone) snap=$(grep -v '^dashboard' <<<"$snap") ;;
                esac
            fi
            : >"$OUT/second"
            printf '%s\n' "$snap"
            ;;
        *'is_appliance'*) printf appliance ;;
        *'systemctl --failed'*) [ "$fault" = unit ] && printf 'pithead-wizard.service loaded failed failed Setup\n' ;;
        esac
    }
    api_state() {
        if [ "$fault" = worker ]; then
            printf '{"workers":[{"name":"rig-a","status":"online"}]}'
        else
            printf '{"workers":[{"name":"rig-a","status":"online"},{"name":"rig-b","status":"online"}]}'
        fi
    }
    rr_wizard_absent() { [ "$fault" != wizard ]; }
    rr_dashboard_response() { [ "$fault" != setup-page ]; }
    OUT=$(mktemp -d)
    trap 'rm -rf "$OUT"' EXIT
    POI_WORKERS=$(printf 'rig-a\nrig-b') POI_FAILURES=0
    post_op_invariants "case"
)

assert_eq "all-good case reports no failing row" "$(drive none)" ""
assert_contains "a worker that does not come back fails" "$(drive worker)" "every worker online before the step"
assert_contains "a changed failures_24h fails" "$(drive failures)" "failures_24h unchanged"
assert_contains "a lingering wizard fails" "$(drive wizard)" "no pithead-wizard container"
assert_contains "the setup page on the web port fails" "$(drive setup-page)" "owns the web response"
assert_contains "a container restart fails" "$(drive restart)" "steady Id, StartedAt and restart count"
assert_contains "a recreated container fails" "$(drive recreate)" "steady Id"
assert_contains "an unhealthy container fails" "$(drive unhealthy)" "steady Id"
assert_contains "a vanished container fails" "$(drive gone)" "steady Id"
assert_contains "a failed pithead unit fails on the appliance" "$(drive unit)" "no failed pithead or xmrig unit"

assert_eq "restarting-then-healthy Caddy is not drift" "$(poi_containers_drift "$SNAP_OK" "$SNAP_OK")" ""
assert_eq "an unreadable failures_24h is a failure" "$(poi_failures_unchanged 0 "" && echo same || echo differ)" "differ"
assert_eq "an xmrig unit is matched" "$(poi_failed_units 'xmrig-proxy.service loaded failed' | wc -l | tr -d ' ')" "1"
assert_eq "an unrelated unit is ignored" "$(poi_failed_units 'chronyd.service loaded failed' | wc -l | tr -d ' ')" "0"

echo "post-op invariants selftest: pass=$IT_PASS fail=$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
