#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329,SC1091,SC1090,SC2016
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

GUEST_OUT="" GUEST_RC=0
_ssh() {
    printf '%s\n' "$GUEST_OUT"
    return "$GUEST_RC"
}
run_verify() {
    oks=() bads=()
    GUEST_OUT="$1" GUEST_RC="$2"
    post_reboot_health_verify lbl
    vrc=$?
}
run_verify $'POH PASS a\nPOH PASS b\nPOH DONE' 0
check "all-pass guest output passes" "$vrc/${#oks[@]}/${#bads[@]}" "0/2/0"
run_verify $'POH PASS a\nPOH FAIL wizard :: still present\nPOH DONE' 1
check "a FAIL row becomes one bad and one ok" "${#oks[@]}/${#bads[@]}" "1/1"
check "the FAIL row text reaches bad" "${bads[0]}" "wizard :: still present"
run_verify $'POH PASS a\r\nPOH DONE\r' 0
check "carriage returns do not hide the finish marker" "$vrc/${#bads[@]}" "0/0"
run_verify $'POH PASS workers' 124
check "a verdict cut off before the finish marker is red" "$vrc/${#bads[@]}" "1/1"
run_verify '' 255
check "no verdict is red, not vacuously green" "$vrc/${#bads[@]}" "1/1"

GUEST_OUT=$'POH_WORKERS=cmlnLWEKcmlnLGIK\nPOH_FAILURES=4' GUEST_RC=0
oks=() bads=()
post_reboot_health_begin
check "snapshot workers parsed" "$(printf '%s' "$POH_BEFORE_WORKERS" | base64 -d)" $'rig-a\nrig,b'
check "snapshot failures parsed" "$POH_BEFORE_FAILURES" 4
GUEST_RC=1
post_reboot_health_begin
check "a failed snapshot is red" "$?/${#bads[@]}" "1/1"

check "run.sh loads the helper" "$(grep -c '^\. "\$SCRIPT_DIR/post-reboot-health.sh"$' "$HERE/run.sh")" 1
order() {
    local f="$HERE/phases/$1" pat last=0 n
    shift
    for pat in "$@"; do
        n=$(grep -nF -- "$pat" "$f" | head -n1 | cut -d: -f1)
        [ -n "$n" ] && [ "$n" -gt "$last" ] || {
            echo "out of order: $pat"
            return
        }
        last=$n
    done
    echo ordered
}
check "stack phase: baseline, restart leg, verify" "$(order stack.sh 'post_reboot_health_begin' '_stack_container_restart_leg ||' 'post_reboot_health_verify "stack"')" ordered
check "provision reboot: log window, baseline, reboot, wrong-password control, verify allowing it" \
    "$(order provision-reboot.sh '--start-window' 'post_reboot_health_begin' '_reboot_wait reboot' 'one external wrong-password attempt counts one failed login' 'post_reboot_health_verify "provision reboot" 1')" ordered

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
guest() (
    export POH_DIR="$tmp" fault="$1"
    export POH_WORKERS POH_CONTAINERS POH_FAILURES=0 POI_STABLE_S=0 POI_RECONNECT_S=0
    POH_WORKERS=$(printf 'rig-a\nrig,b\n' | base64 | tr -d '\n')
    POH_CONTAINERS=$(printf 'caddy\n' | base64 | tr -d '\n')
    snaps="$tmp/snaps.$1"
    : >"$snaps"
    source <(cat "$HERE/post-reboot-health-guest.sh" "$HERE/../integration/lib/reset-restore-web.sh" "$HERE/../integration/lib/post-op-invariants.sh")
    sleep() { :; }
    wait_for() {
        local i
        shift 3
        for i in 1 2 3 4 5; do "$@" && return 0; done
        return 1
    }
    env_on_box() {
        case "$1" in
        HOST_IP) printf 192.0.2.10 ;;
        DASHBOARD_AUTH_HASH_B64) printf x ;;
        esac
    }
    rx() {
        case "$1" in
        *'/api/access'*)
            case "$fault" in
            failures) printf '{"failures_24h": 2}' ;;
            failures-unreadable) : ;;
            *) printf '{"failures_24h": 0}' ;;
            esac
            ;;
        *'ps -q'*)
            printf x >>"$snaps"
            case "$fault" in
            starting) printf 'caddy c1 0 t1 true starting\n' ;;
            starting-clears) [ "$(wc -c <"$snaps")" -gt 2 ] && printf 'caddy c1 0 t1 true healthy\n' || printf 'caddy c1 0 t1 true starting\n' ;;
            gone) : ;;
            *) printf 'caddy c1 0 t1 true healthy\n' ;;
            esac
            ;;
        *'ps -a --format'*)
            printf 'caddy\ndashboard\n'
            [ "$fault" != wizard ] || printf 'pithead-wizard\n'
            ;;
        *'curl --noproxy'*) [ "$fault" = setup-page ] && printf '<title>Pithead setup</title>\n200' || printf 'Unauthorized\n401' ;;
        *'is_appliance'*) printf appliance ;;
        *'systemctl --failed'*) : ;;
        esac
    }
    api_state() {
        if [ "$fault" = state-unreadable ]; then
            return 7
        elif [ "$fault" = worker ]; then
            printf '{"workers":[{"name":"rig-a","status":"online"}]}'
        else
            printf '{"workers":[{"name":"rig-a","status":"online"},{"name":"rig,b","status":"online"}]}'
        fi
    }
    poh_main "$2"
)
out=$(guest none verify)
check "healthy guest passes" "$?" 0
check "healthy guest reports seven PASS rows and finishes" "$(grep -c '^POH PASS' <<<"$out")/$(grep -c '^POH DONE$' <<<"$out")" "7/1"
for case in "wizard:no pithead-wizard container" "setup-page:owns the web response" "failures:failures_24h unchanged" \
    "worker:every worker online before the step" "starting:every running container healthy"; do
    f=${case%%:*}
    out=$(guest "$f" verify)
    check "fault $f is red" "$?" 1
    check "fault $f names only its row" "$(grep -c '^POH FAIL' <<<"$out")/$(grep -c "^POH FAIL .*${case#*:}" <<<"$out")" "1/1"
done
out=$(guest starting-clears verify)
check "a container that finishes starting is waited for, not red" "$?/$(grep -c '^POH FAIL' <<<"$out")" "0/0"
out=$(guest gone verify)
check "a container that never came back is red" "$?/$(grep -c '^POH FAIL .*running again :: not running: caddy' <<<"$out")" "1/1"
for f in state-unreadable failures-unreadable; do
    guest "$f" snapshot >/dev/null
    check "an unreadable snapshot ($f) fails" "$?" 1
done
out=$(guest worker verify)
check "worker fault names the missing worker" "$(grep -c '^POH FAIL .*rig,b' <<<"$out")" 1
out=$(guest none snapshot)
check "snapshot round-trips worker names" "$(sed -n 's/^POH_WORKERS=//p' <<<"$out" | base64 -d)" $'rig,b\nrig-a'
[ "$fails" -eq 0 ] && echo "post-reboot health selftest passed"
exit "$fails"
