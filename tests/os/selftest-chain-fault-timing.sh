#!/usr/bin/env bash
# Tier-1 debounce deadline and negative-control regressions; no guest or containers.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/appliance-chain-fault-leg.sh
. "$HERE/appliance-chain-fault-leg.sh"

_ssh() {
    printf '%s' "$fixture_env"
    return "$ssh_rc"
}
ssh_rc=0
for fixture in '[]|900' '["OTHER=value"]|900' \
    '["TARI_NODE_DOWN_AFTER_SEC=1200"]|1200' \
    '["TARI_NODE_DOWN_AFTER_SEC=0005"]|5' \
    '["TARI_NODE_DOWN_AFTER_SEC=3600"]|3600'; do
    fixture_env=${fixture%|*}
    [ "$(chain_fault_down_after)" = "${fixture##*|}" ]
done
for fixture_env in '' '{}' '["TARI_NODE_DOWN_AFTER_SEC="]' \
    '["TARI_NODE_DOWN_AFTER_SEC=-1"]' '["TARI_NODE_DOWN_AFTER_SEC=0"]' \
    '["TARI_NODE_DOWN_AFTER_SEC=3601"]' '["TARI_NODE_DOWN_AFTER_SEC=999999999999999999"]' \
    '["TARI_NODE_DOWN_AFTER_SEC=1+2"]' \
    '["TARI_NODE_DOWN_AFTER_SEC=5","TARI_NODE_DOWN_AFTER_SEC=10"]'; do
    if chain_fault_down_after >/dev/null 2>&1; then
        echo "invalid debounce accepted: $fixture_env" >&2
        exit 1
    fi
done
fixture_env='[]' ssh_rc=1
if chain_fault_down_after >/dev/null 2>&1; then
    echo 'unreadable guest environment accepted' >&2
    exit 1
fi

chain_fault_now() { printf '%s\n' "$tick"; }
sleep() { tick=$((tick + $1)); }
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); }
chain_fault_state() {
    if [ "$unreadable" = 1 ] && [ "$tick" -lt "$debounce" ]; then
        printf 'not-json'
    elif [ "$tick" -ge "$appears_at" ]; then
        printf '{"badges":[{"text":"Tari DOWN"}]}'
    else
        printf '{"badges":[]}'
    fi
}
scenario() { # <debounce> <badge-at> <unreadable-early> <want-negative> <want-late>
    local debounce="$1" appears_at="$2" unreadable="$3" tick=0 PASS=0 FAIL=0 state late=0
    chain_fault_wait_badge "$debounce" 0 && late=1
    [ "$PASS/$FAIL" = "$4" ] && [ "$late" = "$5" ] || {
        printf 'debounce %s, badge at %s: negative %s/%s, late %s\n' "$debounce" "$appears_at" "$PASS" "$FAIL" "$late" >&2
        return 1
    }
    [ "$tick" -le $((debounce + 185)) ]
    if [ "$late" = 1 ]; then [ "$tick" -ge "$debounce" ]; fi
    return 0
}
# A badge at the production default exceeds the old five-minute deadline.
scenario 900 900 0 1/0 1
# An overridden debounce, with collection/publish delay, determines the deadline.
scenario 1200 1300 0 1/0 1
scenario 900 0 0 0/1 1
scenario 900 895 0 0/1 1
scenario 900 2000 0 1/0 0
scenario 900 900 1 0/1 1
scenario 1 185 0 1/0 0
scenario 5 185 0 1/0 1
# Use the real Python-clock call with a failed command or malformed output.
(
    python3() {
        printf '%s' "$clock_output"
        return "$clock_rc"
    }
    # Restore the production reader; the polling scenarios above use a fake clock.
    chain_fault_now() { python3 -I -c 'import time; print(int(time.monotonic()))'; }
    clock_rc=0 clock_output=0005
    [ "$(chain_fault_clock_read)" = 5 ]
    for clock_output in '' 'not-a-number' '-1' '1+2' '9999999999999'; do
        if chain_fault_clock_read; then exit 1; fi
    done
    clock_rc=127 clock_output=5
    if chain_fault_clock_read; then exit 1; fi
)

# Drive the complete leg, proving failure before injection and recovery after injection.
(
    chain_fault_down_after() { printf '5\n'; }
    chain_fault_probe() { printf '1000 900 2000 0\n'; }
    provisioning_settled() { return 0; }
    info() { :; }
    bad() {
        FAIL=$((FAIL + 1))
        errors+="$*"
    }
    _ssh() {
        case "$*" in
        *'podman ps -q'*) printf 'fixture\n' ;;
        *'podman stop'*) stopped=1 ;;
        *'pithead up'*) stopped=0 upped=1 ;;
        *) return 1 ;;
        esac
    }
    chain_fault_status() {
        if [ "$stopped" = 1 ]; then
            printf '  ✗ tari exited\n'
            return 1
        fi
        printf '  ✓ tari running\n'
    }
    chain_fault_doctor() {
        if [ "$stopped" = 1 ]; then
            printf '{"exit":1,"checks":[{"status":"fail","message":"tari is down"}]}'
        else
            printf '{"exit":0,"checks":[{"status":"ok","message":"Revenue healthy"}]}'
        fi
    }
    chain_fault_state() { printf '{"badges":[]}'; }
    chain_fault_now() {
        if { [[ "$mode" = initial* ]] && [ "$upped/$stopped" = 0/0 ]; } ||
            { [[ "$mode" = poll* ]] && [ "$stopped" = 1 ] && [ "$tick" -ge "$clock_fail_at" ]; }; then
            case "$mode" in
            *exit)
                printf '5'
                return 127
                ;;
            *empty) return 0 ;;
            *text) printf 'not-a-number' ;;
            *backward) printf '104' ;;
            esac
        else
            printf '%s\n' "$((100 + tick))"
        fi
    }
    for mode in initial-exit initial-empty initial-text poll-exit poll-empty poll-text poll-backward; do
        stopped=0 upped=0 tick=0 PASS=0 FAIL=0 errors='' clock_fail_at=5
        if [ "$mode" = poll-backward ]; then clock_fail_at=10; fi
        phase_provision_chain_fault_after_release u p || :
        [[ "$errors" = *'monotonic clock'* ]]
        if [[ "$mode" = initial* ]]; then
            [ "$stopped/$upped/$PASS/$FAIL" = 0/0/1/1 ]
        else
            # Timing must fail, but all unchanged stopped/recovered surface checks still run.
            [ "$stopped/$upped/$PASS/$FAIL" = 0/1/8/2 ]
            [ "$tick" -eq "$clock_fail_at" ]
        fi
    done
)
echo 'selftest-chain-fault-timing: PASS'
