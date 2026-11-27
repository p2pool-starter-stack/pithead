#!/usr/bin/env bash
# Run the hardening wallet refusal leg against the real host CLI, without containers.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/stack/lib.sh
source "$HERE/../../stack/lib.sh"
# shellcheck source=tests/integration/fixtures/payout-pairs.sh
source "$HERE/../fixtures/payout-pairs.sh"
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-hardening.sh
source "$HERE/../lib/run-hardening.sh"

echo "== hardening wallet preview reaches the typed confirmation gate =="

# Execute the live leg itself, including its payload construction and confirmation assertions.
LEG="$(sed -n '/^        local uuid_bad /,/^    fi$/p' "$HERE/../lib/run-hardening.sh" | sed '$d')"
assert_contains "wallet leg is present" "$LEG" 'wallet spool preview needs typed confirmation'
IT_MODE=local
rx() { (cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" bash -c "$1"); }
quote_arg() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
env_on_box() { sed -n "s/^$1=//p" "$C/.env"; }
# Substitute only the systemd trigger/poll: the real CLI claims and processes each request.
_wait_control_status() {
    run_pending >"$SANDBOX/runner.log" 2>&1 || return 1
    jq -r '.status // empty' "$1/results/$2.json"
}
it_pass() { ok "$1"; }
it_fail() { bad "$1" "$2"; }
wallet_leg() {
    local ctrl_config cdir before
    ctrl_config="$(cat "$C/config.json")"
    cdir="$C/data/control"
    before="$(sha256sum "$C/config.json" "$C/.env")"
    eval "$LEG"
    assert_eq "wallet refusal preserves complete config and env" \
        "$(sha256sum "$C/config.json" "$C/.env")" "$before"
}
for view in "$PAYOUT_VIEW1" ''; do
    rm -rf "$SANDBOX/control"
    # shellcheck disable=SC2034 # consumed by build_control_sandbox/control_config
    WALLET="$PAYOUT_MONERO1"
    build_control_sandbox
    cp "$ROOT/VERSION" "$C/VERSION"
    seed_control_env
    control_config main
    jq --arg k "$view" '.monero.view_key=$k' "$C/config.json" >"$C/candidate"
    mv "$C/candidate" "$C/config.json"
    out="$(rx './pithead apply -y')"
    assert_rc "baseline with view key length ${#view} applies using stub I/O" "$?" 0
    wallet_leg
done
printf 'selftest-hardening-wallet: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
