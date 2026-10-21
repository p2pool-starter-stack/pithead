BASELINE = {
    "dashboard": {"secure": False, "onion": {"enabled": False, "client_auth": True}},
    "monero": {"mode": "local", "wallet_address": "4" + "A" * 94},
}
BASE_ENV = (
    "COMPOSE_PROFILES=local_node\nDASHBOARD_ONION_ENABLED=false\nDASHBOARD_ONION_CLIENT_AUTH=true\n"
    "DASHBOARD_ONION_ADDRESS=placeholder\nDASHBOARD_ONION_CLIENT_PRIVKEY=placeholder\n"
)

# Fresh synthetic credentials reveal reuse between authorized probes.
PITHEAD = r"""#!/usr/bin/env bash
umask 077
envset() { if grep -q "^$1=" .env; then sed "s|^$1=.*|$1=$2|" .env >.env.t && mv .env.t .env; else echo "$1=$2" >>.env; fi; }
envget() { sed -n "s/^$1=//p" .env | head -n1; }
case "$1" in
apply)
    on=$(jq -r '.dashboard.onion.enabled // false' config.json)
    ca=$(jq -r 'if .dashboard.onion.client_auth == false then "false" else "true" end' config.json)
    ctl=$(jq -r '.dashboard.control.enabled // false' config.json)
    echo "apply onion=$on client_auth=$ca control=$ctl" >>"$STUB/events.log"
    if [ "$on" = true ] && [ "$ca" = false ] && [ "$ctl" = true ]; then exit 1; fi
    envset DASHBOARD_ONION_ENABLED "$on"
    if [ "$on" = true ]; then
        mkdir -p "$STUB/box/tor/dashboard"
        printf 'synthetic identity\n' >"$STUB/box/tor/dashboard/hs_ed25519_secret_key"
        chmod 700 "$STUB/box/tor/dashboard"
        chmod 600 "$STUB/box/tor/dashboard/hs_ed25519_secret_key"
    fi
    envset DASHBOARD_ONION_CLIENT_AUTH "$ca"
    if [ "$on" = true ] && [ "$(envget DASHBOARD_ONION_ADDRESS)" = placeholder ]; then
        envset DASHBOARD_ONION_ADDRESS "$(printf 'b%.0s' $(seq 56)).onion"
        envset DASHBOARD_ONION_CLIENT_PRIVKEY "SYNTHETICCLIENTKEY"
    fi
    if [ "$on" = true ] && [ "${APPLY_FAIL:-0}" = 1 ]; then
        echo "apply-result failed" >>"$STUB/events.log"
        exit 1
    fi
    echo "apply-result ok" >>"$STUB/events.log" ;;
onion-client-key)
    if [ "$(envget DASHBOARD_ONION_ENABLED)" = true ] && [ "$(envget DASHBOARD_ONION_CLIENT_AUTH)" = true ] &&
        [ "$(envget DASHBOARD_ONION_ADDRESS)" != placeholder ]; then
        echo x >>"$STUB/keys"
        n=$(wc -l <"$STUB/keys" | tr -d ' ')
        envset DASHBOARD_ONION_CLIENT_PRIVKEY "SYNTHETICCLIENTKEY$(printf '%s' "$n" | tr '1234567890' 'ABCDEFGHIJ')"
        if [ "$n" = "${CLIENT_EMPTY_ON:-}" ]; then
            echo "client-key empty" >>"$STUB/events.log"
            exit 0
        fi
        if [ "$n" = "${CLIENT_FAIL_ON:-}" ]; then
            echo "client-key refused" >>"$STUB/events.log"
        else
            echo "client-key ok" >>"$STUB/events.log"
        fi
        a=$(envget DASHBOARD_ONION_ADDRESS)
        printf 'Dashboard onion address:  http://%s\n\n    %s:descriptor:x25519:%s\n' "$a" "${a%.onion}" "$(envget DASHBOARD_ONION_CLIENT_PRIVKEY)"
        [ "$n" != "${CLIENT_FAIL_ON:-}" ] || exit 1
    else
        echo "client-key refused" >>"$STUB/events.log"
        echo "no client key" >&2
        exit 1
    fi ;;
restart) echo "restart $2" >>"$STUB/events.log" ;;
esac
exit 0
"""
# The fake client follows the probe exit-code and stdin authorization contracts.
DOCKER = r"""#!/usr/bin/env bash
case "$1" in
ps) echo synthetic ;;
inspect) echo '[{"Mounts":[]}]' ;;
exec) echo "touch: cannot touch '/.rootfs-write-probe': Read-only file system"; exit 1 ;;
run)
    addr="" stdin_key=0
    for a in "$@"; do case "$a" in ONION_ADDR=*) addr=${a#ONION_ADDR=} ;; AUTH_STDIN=1) stdin_key=1 ;; esac; done
    line=""
    [ "$stdin_key" = 1 ] && read -r line
    box="$STUB/box"
    want=$(sed -n 's/^DASHBOARD_ONION_ADDRESS=//p' "$box/.env")
    key=$(sed -n 's/^DASHBOARD_ONION_CLIENT_PRIVKEY=//p' "$box/.env")
    ca=$(sed -n 's/^DASHBOARD_ONION_CLIENT_AUTH=//p' "$box/.env")
    on=$(sed -n 's/^DASHBOARD_ONION_ENABLED=//p' "$box/.env")
    echo x >>"$STUB/probes"
    n=$(wc -l <"$STUB/probes" | tr -d ' ')
    keyed=no
    [ "$line" = "${want%.onion}:descriptor:x25519:$key" ] && keyed=yes
    ok=0
    if [ "$on" = true ] && [ "$addr" = "$want" ] && { [ "$ca" != true ] || [ "$keyed" = yes ]; }; then
        case ",${PROBE_FAIL_ON:-}," in *",$n,"*) ;; *) ok=1 ;; esac
    fi
    clean=yes
    if [ "$stdin_key" = 0 ]; then
        [ -z "$line" ] || clean=no
        case "${KEYLESS_RESULT:-}" in
        reachable) ok=1 ;;
        bootstrap) echo "probe $n keyed=no clean=$clean" >>"$STUB/events.log"; echo "PROBE-FAIL: tor did not bootstrap"; exit 2 ;;
        error) echo "probe $n keyed=no clean=$clean" >>"$STUB/events.log"; echo "unexpected failure"; exit 3 ;;
        esac
    fi
    echo "probe $n clean=$clean onion=$([ "$addr" = "$want" ] && echo provisioned || echo other) keyed=$keyed ok=$ok" >>"$STUB/events.log"
    if [ "$ok" = 1 ]; then echo "PROBE-OK: reachable"; exit 0; else echo "PROBE-FAIL: HTTP 000"; exit 1; fi ;;
esac
exit 0
"""
DRIVER = r"""
set -uo pipefail
HERE="$PWD/tests/integration"
INTEGRATION_RUN_SUITE=1
while IFS= read -r lib; do
    # shellcheck disable=SC1090
    source "$HERE/$lib" >/dev/null 2>&1 || { echo "DRIVER-ERROR: cannot source $lib"; exit 90; }
done < <(sed -n 's|^source "\$HERE/\([^"]*\)".*|\1|p' "$HERE/run.sh")
declare -F run_hardening >/dev/null || { echo "DRIVER-ERROR: run_hardening is not defined"; exit 91; }
IT_MODE=local IT_REMOTE_DIR="$STUB/box" IT_PITHEAD=./pithead IT_CURRENT_SCENARIO=hardening OUT_DIR="$STUB/out"
BASELINE_CONFIG="${RUN_BASELINE_CONFIG:-$(cat "$STUB/box/config.json")}"
_SAFETY_RESTORE_ARMED=0 _SAFETY_FOREIGN_TRAP="" SAFETY_ARCHIVE="" SAFETY_RESTORE_FAILED=0
export PATH="$STUB:$PATH"
wait_status_ok() { return 0; }
wait_for() { return 0; }
sleep() { :; }
capture_artifacts() { :; }
if [ "${INTERRUPT_PROBE:-0}" = 1 ]; then
    _onion_reachable_external() { kill -TERM $$; }
fi
run_hardening
"""

SUDO = r"""#!/usr/bin/env bash
[ "$1" != -n ] || shift
if [ "${3:-}" = restore ] && [ "${RESTORE_FAIL_ONCE:-0}" = 1 ]; then
    if [ ! -e "$STUB/restore-attempted" ]; then
        touch "$STUB/restore-attempted"
        "$@" || exit $?
        exit 1
    fi
fi
exec "$@"
"""
