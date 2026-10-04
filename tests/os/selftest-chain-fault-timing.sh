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
echo 'selftest-chain-fault-timing: PASS'
