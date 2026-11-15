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
for node in PITHEAD_OS_MONERO_NODE_HOST=nodehost-sentinel PITHEAD_OS_TARI_NODE_HOST=tarihost-sentinel; do
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
guard PITHEAD_OS_MONERO_NODE_USERNAME=user-sentinel PITHEAD_OS_MONERO_NODE_PASSWORD=pass-sentinel || fail "refused on node credentials alone"
guard PITHEAD_OS_MONERO_NODE_HOST="" || fail "refused with an empty node variable"

(
    source "$HERE/restore-live-state-verdict.sh" || exit 1
    out=$(restore_live_state_verdict "dashboard caddy" "${OWNER_M}live" "$OWNER_M") && exit 2
    case "$out" in *"$OWNER_M"*) exit 3 ;; esac
) || fail "restore_live_state_verdict printed or accepted a wallet (exit $?)"

run_sh="$HERE/run.sh"
payout_line=$(grep -nx 'require_owner_payouts' "$run_sh" | head -1 | cut -d: -f1)
host_line=$(grep -nx 'require_host' "$run_sh" | head -1 | cut -d: -f1)
{ [ -n "$payout_line" ] && [ -n "$host_line" ] && [ "$payout_line" -lt "$host_line" ]; } ||
    fail "run.sh does not call require_owner_payouts before require_host"

if grep -nE '(^|[^A-Za-z_])\.?xvb\.donor_id *=|donor_id *:' "$HERE"/*.sh "$HERE"/phases/*.sh "$HERE"/lib/*.sh |
    grep -v '/selftest-' | grep -q .; then
    fail "a guest config sets xvb.donor_id; it must stay auto so the identity is the owner's wallet prefix"
fi
strays=$(grep -lE '\b4[0-9AB][0-9A-Za-z]{90,}|\b12[0-9A-Za-z]{80,}' "$HERE"/*.sh "$HERE"/phases/*.sh "$HERE"/lib/*.sh |
    grep -Ev '/selftest-|/lib/core\.sh$|/phases/media\.sh$|/appliance-tari-wallet-leg\.sh$' || true)
[ -z "$strays" ] || fail "a wallet literal outside core.sh reaches a guest: $strays"

! grep -qE 'HARNESS_(WALLET|TARI)' "$HERE/phases/media.sh" ||
    fail "media.sh uses the owner payouts; its sticks must keep their own throwaway addresses"
! grep -q 'DONATION' "$HERE/rig-adopt-leg.sh" ||
    fail "rig-adopt-leg.sh touches DONATION on a guest that mines at the coordinator"

(
    export PITHEAD_OS_PAYOUT_MONERO=$OWNER_M PITHEAD_OS_PAYOUT_TARI=$OWNER_T
    source "$HERE/lib/core.sh" || exit 1
    trap - EXIT
    source "$HERE/phases/image-upgrade.sh" || exit 1
    stage=$(mktemp -d)
    trap 'rm -f "$stage/monero-pass"; rmdir "$stage"' EXIT
    : >"$stage/monero-pass"
    PITHEAD_OS_MONERO_RPC_PORT=18081 PITHEAD_OS_MONERO_ZMQ_PORT=18083
    printf '{}' | _image_upgrade_owner_config 192.0.2.1 192.0.2.2 "$stage" |
        jq -e --arg m "$OWNER_M" --arg t "$OWNER_T" \
            '.monero.wallet_address == $m and .tari.wallet_address == $t and .monero.remote.host == "192.0.2.1"' >/dev/null || exit 11
) || fail "the image-upgrade guest config does not carry the owner payouts (exit $?)"

grep -q 'stack_browser_config' <(sed -n '/^_provision_remote_node_coordinator()/,/^}/p' "$HERE/phases/stack.sh") ||
    fail "the rig share-leg coordinator is not built by stack_browser_config"
grep -q '_wizard_provision_capture' "$HERE/migration-recovery.sh" &&
    grep -q 'provision_browser_submit' "$HERE/phases/provision-initial.sh" ||
    fail "migration recovery no longer provisions through the payout-aware browser submit"

(
    source "$HERE/lib/redact-addr.sh" || exit 1
    addr="4$(printf 'A%.0s' $(seq 94))"
    out=$(printf 'peer %s ok\n--wallet %s --x\n' "$addr" "$addr" | os_redact_addr)
    case "$out" in *AAAAAAAAAAAAAAAAAAAA*) exit 2 ;; esac
    case "$out" in *'[redacted-address]'*) ;; *) exit 3 ;; esac
    out=$(printf '\033[1;33m%s\033[0m\n' "$addr" | os_redact_addr)
    case "$out" in *AAAAAAAAAAAAAAAAAAAA*) exit 4 ;; esac
    out=$(printf "[ERROR] monero.wallet_address ('4AbCdE…') fails its checksum\n[ERROR] x ('4AbCdE…', 12 chars) bad\n" | os_redact_addr)
    case "$out" in *4AbCdE*) exit 5 ;; esac
    case "$out" in *'[redacted-prefix]'*) ;; *) exit 6 ;; esac
) || fail "os_redact_addr leaves an address in a log line (exit $?)"

echo 'selftest-owner-payouts: PASS (overrides, fallbacks, early refusal, no values echoed, no donor id, no stray wallet literal)'
