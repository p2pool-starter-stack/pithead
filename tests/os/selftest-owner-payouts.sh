#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() {
    echo "selftest-owner-payouts: $1" >&2
    exit 1
}
OWNER_M="owner-monero-sentinel-0001"
OWNER_T="owner-tari-sentinel-0002"
SERIAL=$(mktemp)
trap 'rm -f "$SERIAL"' EXIT
PASS=0 FAIL=0 OS_RUN_SUITE=1 SCRIPT_DIR="$HERE"
unset PITHEAD_OS_PAYOUT_MONERO PITHEAD_OS_PAYOUT_TARI PITHEAD_OS_MONERO_NODE_HOST \
    PITHEAD_OS_TARI_NODE_HOST PITHEAD_OS_MONERO_NODE_USERNAME PITHEAD_OS_MONERO_NODE_PASSWORD

(
    # shellcheck source=tests/os/lib/core.sh
    source "$HERE/lib/core.sh" || exit 1
    trap - EXIT
    # shellcheck source=tests/os/provision-browser-submit.sh
    source "$HERE/provision-browser-submit.sh" || exit 1
    # shellcheck source=tests/os/appliance-node-runtime-leg.sh
    source "$HERE/appliance-node-runtime-leg.sh" || exit 1
    # shellcheck source=tests/os/phases/stack.sh
    source "$HERE/phases/stack.sh" || exit 1
    default_m=$HARNESS_WALLET default_t=$HARNESS_TARI
    [ -n "$default_m" ] && [ -n "$default_t" ] || exit 11
    cfg=$(stack_browser_config '{}' mh 1 2 u p th 3) || exit 12
    printf '%s' "$cfg" | jq -e --arg m "$default_m" --arg t "$default_t" \
        '.monero.wallet_address == $m and .tari.wallet_address == $t' >/dev/null || exit 13
    cfg=$(stack_browser_config '{}' mh 1 2 u p "" 0) || exit 14
    printf '%s' "$cfg" | jq -e --arg m "$default_m" '.monero.wallet_address == $m' >/dev/null || exit 15
    (
        export PITHEAD_OS_PAYOUT_MONERO="" PITHEAD_OS_PAYOUT_TARI=""
        source "$HERE/lib/core.sh" || exit 1
        trap - EXIT
        [ "$HARNESS_WALLET" = "$default_m" ] && [ "$HARNESS_TARI" = "$default_t" ]
    ) || exit 16
) || fail "defaults without payout variables changed (exit $?)"

(
    export PITHEAD_OS_PAYOUT_MONERO=$OWNER_M PITHEAD_OS_PAYOUT_TARI=$OWNER_T
    # shellcheck source=tests/os/lib/core.sh
    source "$HERE/lib/core.sh" || exit 1
    trap - EXIT
    # shellcheck source=tests/os/provision-browser-submit.sh
    source "$HERE/provision-browser-submit.sh" || exit 1
    # shellcheck source=tests/os/appliance-node-runtime-leg.sh
    source "$HERE/appliance-node-runtime-leg.sh" || exit 1
    # shellcheck source=tests/os/phases/stack.sh
    source "$HERE/phases/stack.sh" || exit 1
    [ "$HARNESS_WALLET" = "$OWNER_M" ] && [ "$HARNESS_TARI" = "$OWNER_T" ] || exit 11
    for cfg in "$(stack_browser_config '{}' mh 1 2 u p th 3)" "$(stack_browser_config '{}' mh 1 2 u p "" 0)" \
        "$(provision_browser_config '{}')"; do
        printf '%s' "$cfg" | jq -e --arg m "$OWNER_M" '.monero.wallet_address == $m' >/dev/null || exit 12
    done
    stack_browser_config '{}' mh 1 2 u p th 3 | jq -e --arg t "$OWNER_T" '.tari.wallet_address == $t' >/dev/null || exit 13
    provision_browser_config '{}' | jq -e --arg t "$OWNER_T" '.tari.wallet_address == $t' >/dev/null || exit 14
) || fail "guest config builders ignore the owner payout variables (exit $?)"

guard() ( # <env assignments...>; prints the refusal on stderr and returns its status
    local a
    for a in "$@"; do export "${a%%=*}=${a#*=}"; done
    source "$HERE/lib/core.sh" || exit 99
    trap - EXIT
    require_owner_payouts
)
refused() {
    local out rc
    out=$(guard "$@" 2>&1 >/dev/null)
    rc=$?
    [ "$rc" -ne 0 ] || fail "accepted: $*"
    printf '%s' "$out"
}
for node in PITHEAD_OS_MONERO_NODE_HOST=nodehost-sentinel PITHEAD_OS_TARI_NODE_HOST=tarihost-sentinel PITHEAD_OS_MONERO_NODE_USERNAME=user-sentinel PITHEAD_OS_MONERO_NODE_PASSWORD=pass-sentinel; do
    out=$(refused "$node")
    case "$out" in *PITHEAD_OS_PAYOUT_MONERO*PITHEAD_OS_PAYOUT_TARI*) ;; *) fail "refusal does not name both variables for $node" ;; esac
    out=$(refused "$node" PITHEAD_OS_PAYOUT_MONERO="" PITHEAD_OS_PAYOUT_TARI=$OWNER_T)
    case "$out" in *PITHEAD_OS_PAYOUT_MONERO*) ;; *) fail "refusal does not name the empty monero variable" ;; esac
    case "$out" in *PITHEAD_OS_PAYOUT_TARI*) fail "refusal names the set tari variable" ;; esac
    case "$out" in *"$OWNER_T"* | *"${node#*=}"*) fail "refusal printed a value" ;; esac
    out=$(refused "$node" PITHEAD_OS_PAYOUT_MONERO=$OWNER_M)
    case "$out" in *PITHEAD_OS_PAYOUT_TARI*) ;; *) fail "refusal does not name the missing tari variable" ;; esac
    case "$out" in *"$OWNER_M"*) fail "refusal printed the monero value" ;; esac
    guard "$node" PITHEAD_OS_PAYOUT_MONERO=$OWNER_M PITHEAD_OS_PAYOUT_TARI=$OWNER_T || fail "refused with both payouts set for $node"
done
guard PITHEAD_OS_RIG_SHARE_WINDOW_SEC=5 || fail "refused without node variables"
guard PITHEAD_OS_MONERO_NODE_HOST="" || fail "refused with an empty node variable"

if grep -nE '(^|[^A-Za-z_])\.?xvb\.donor_id *=|donor_id *:' "$HERE"/*.sh "$HERE"/phases/*.sh "$HERE"/lib/*.sh |
    grep -v '/selftest-' | grep -q .; then
    fail "a guest config sets xvb.donor_id; it must stay auto so the identity is the owner's wallet prefix"
fi
strays=$(grep -lE '\b4[0-9AB][0-9A-Za-z]{90,}|\b12[0-9A-Za-z]{80,}' "$HERE"/*.sh "$HERE"/phases/*.sh "$HERE"/lib/*.sh |
    grep -Ev '/selftest-|/lib/core\.sh$|/phases/media\.sh$|/appliance-tari-wallet-leg\.sh$' || true)
[ -z "$strays" ] || fail "a wallet literal outside core.sh reaches a guest: $strays"

echo 'selftest-owner-payouts: PASS (overrides, fallbacks, early refusal, no values echoed, no donor id, no stray wallet literal)'
