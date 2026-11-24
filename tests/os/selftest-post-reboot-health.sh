#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329,SC1091,SC1090
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$HERE"
fails=0
check() {
    if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else
        printf 'FAIL %s: got [%s] want [%s]\n' "$1" "$2" "$3"
        fails=$((fails + 1))
    fi
}

source "$HERE/post-reboot-health.sh"
ok() { oks+=("$1"); }
bad() { bads+=("$1"); }
info() { :; }

payload=$(_poh_payload verify)
check "payload carries the shared invariants and the driver" "$(grep -c '^post_op_invariants()\|^poh_main()\|^rr_dashboard_response()' <<<"$payload")" 3
check "payload ends by calling the mode" "$(tail -n1 <<<"$payload")" "poh_main verify"

run_verify() {
    oks=() bads=()
    _ssh() {
        printf '%s\n' "$GUEST_OUT"
        return "$GUEST_RC"
    }
    GUEST_OUT="$1" GUEST_RC="$2" post_reboot_health_verify lbl
    echo $?
}
rc=$(run_verify $'POH PASS a\nPOH PASS b' 0)
check "all-pass guest output passes" "$rc" 0
rc=$(run_verify $'POH PASS a\nPOH FAIL wizard :: still present' 1)
check "a FAIL row is red" "$rc" 1
rc=$(run_verify '' 255)
check "no verdict is red, not vacuously green" "$rc" 1

_ssh() { printf 'POH_WORKERS=rig-a,rig-b\nPOH_FAILURES=4\n'; }
post_reboot_health_begin
check "snapshot workers parsed" "$POH_BEFORE_WORKERS" "rig-a,rig-b"
check "snapshot failures parsed" "$POH_BEFORE_FAILURES" 4

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
guest() (
    export POH_DIR="$tmp" fault="$1"
    export POH_WORKERS=rig-a POH_FAILURES=0 POI_STABLE_S=0 POI_RECONNECT_S=0
    source <(cat "$HERE/post-reboot-health-guest.sh" "$HERE/../integration/lib/reset-restore-web.sh" "$HERE/../integration/lib/post-op-invariants.sh")
    sleep() { :; }
    wait_for() {
        shift 3
        "$@"
    }
    rx() {
        case "$1" in
        *'/api/access'*) [ "$fault" = failures ] && printf '{"failures_24h": 2}' || printf '{"failures_24h": 0}' ;;
        *'ps -q'*) printf 'caddy c1 0 t1 true healthy\n' ;;
        *'is_appliance'*) printf appliance ;;
        *'systemctl --failed'*) : ;;
        esac
    }
    api_state() { printf '{"workers":[{"name":"rig-a","status":"online"}]}'; }
    rr_wizard_absent() { [ "$fault" != wizard ]; }
    rr_dashboard_response() { [ "$fault" != setup-page ]; }
    poh_main "$2"
)
out=$(guest none verify)
check "healthy guest passes" "$?" 0
check "healthy guest reports PASS rows" "$(grep -c '^POH PASS' <<<"$out" | tr -d ' ')" 6
for f in wizard setup-page failures; do
    out=$(guest "$f" verify)
    check "fault $f is red" "$?" 1
done
out=$(guest wizard verify)
check "wizard fault names the wizard row" "$(grep -c '^POH FAIL .*no pithead-wizard container' <<<"$out" | tr -d ' ')" 1
out=$(guest setup-page verify)
check "setup-page fault names the dashboard row" "$(grep -c '^POH FAIL .*owns the web response' <<<"$out" | tr -d ' ')" 1
out=$(guest failures verify)
check "failures fault names the failures row" "$(grep -c '^POH FAIL .*failures_24h unchanged' <<<"$out" | tr -d ' ')" 1
[ "$fails" -eq 0 ] && echo "post-reboot health selftest passed"
exit "$fails"
