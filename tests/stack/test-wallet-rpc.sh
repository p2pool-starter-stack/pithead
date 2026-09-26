# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Monero payout wallet (wallet-rpc): the view-only create-from-keys gen.json of the wallet
# entrypoint and the scan-grace healthcheck (#381/#714/#718). Moved out of test-monero-tari.sh,
# which sat at its budget ceiling. Sourced by tests/stack/run.sh.

: "${ROOT:?}" "${SANDBOX:?}"

# --- Wallet entrypoint (#381/#714): the view-only create-from-keys JSON must OMIT the spend key.
# monero-wallet-rpc v0.18 parses an empty-string "spendkey":"" as a secret key and aborts wallet
# creation ("failed to parse spend key secret key"), so the field's ABSENCE — not "" — is what
# lets the payout wallet build. This exercises the REAL entrypoint's write_gen_json.
echo "== unit: wallet-entrypoint view-only gen.json omits spendkey (#714) =="
# shellcheck disable=SC1090
(
    export PITHEAD_TEST_SOURCE=1
    source "$ROOT/build/monero/wallet-entrypoint.sh"
    export GEN_JSON="$SANDBOX/wallet-gen.json" WALLET_FILE="$SANDBOX/payout-wallet"
    export MONERO_WALLET_ADDRESS="48exampleAddr" MONERO_VIEW_KEY="deadbeefdeadbeef"
    write_gen_json 3000000
)
WGEN="$(cat "$SANDBOX/wallet-gen.json")"
if printf '%s' "$WGEN" | jq -e . >/dev/null 2>&1; then ok "wallet gen.json is valid JSON (#714)"; else bad "wallet gen.json is valid JSON (#714)" "jq rejected: $WGEN"; fi
assert_eq "wallet gen.json carries the address (#381)" "$(printf '%s' "$WGEN" | jq -r .address)" "48exampleAddr"
assert_eq "wallet gen.json carries the view key (#381)" "$(printf '%s' "$WGEN" | jq -r .viewkey)" "deadbeefdeadbeef"
assert_eq "wallet gen.json scan_from_height verbatim (#381)" "$(printf '%s' "$WGEN" | jq -r .scan_from_height)" "3000000"
# THE REGRESSION GUARD: a revert to "spendkey":"" crashes monero-wallet-rpc (#714). Field must be absent.
assert_eq "wallet gen.json OMITS spendkey — monero rejects an empty one (#714)" "$(printf '%s' "$WGEN" | jq 'has("spendkey")')" "false"
# Restore height: "auto"/empty means genesis (0) so the wallet scans the FULL payout history; an
# explicit height is used verbatim to skip the long scan.
rsh() { (
    export PITHEAD_TEST_SOURCE=1 PAYOUT_SCAN_HEIGHT="$1"
    source "$ROOT/build/monero/wallet-entrypoint.sh"
    resolve_scan_height
); }
assert_eq "scan height: auto -> genesis 0 (full payout history)" "$(rsh auto)" "0"
assert_eq "scan height: empty -> genesis 0" "$(rsh '')" "0"
assert_eq "scan height: explicit block kept verbatim" "$(rsh 2500000)" "2500000"

# Wallet healthcheck (#718/#2268): stub `curl` on PATH to control RPC up/down.
HCBIN="$SANDBOX/hc-bin"
HCDIR="$SANDBOX/hc-wallet"
mkdir -p "$HCBIN" "$HCDIR"
mk_curl() {
    printf '#!/bin/sh\nexit %s\n' "$1" >"$HCBIN/curl"
    chmod +x "$HCBIN/curl"
}
run_hc() { (
    PATH="$HCBIN:$PATH" WALLET_DIR="$HCDIR" sh "$ROOT/build/monero/wallet-healthcheck.sh" >/dev/null 2>&1
    echo $?
); }
mk_curl 7
: >"$HCDIR/.payout-scanning"
assert_eq "healthcheck: RPC down with fresh scan marker -> healthy (#718)" "$(run_hc)" "0"
assert_eq "healthcheck: zero scan grace expires immediately (#2268)" "$(PAYOUT_SCAN_GRACE_SEC=0 run_hc)" "1"
touch -t 200001010000.00 "$HCDIR/.payout-scanning"
assert_eq "healthcheck: RPC down with expired scan marker -> unhealthy (#2268)" "$(run_hc)" "1"
: >"$HCDIR/.payout-scanning"
mk_curl 0
assert_eq "healthcheck: RPC up -> healthy (#718)" "$(run_hc)" "0"
if [ -f "$HCDIR/.payout-scanning" ]; then bad "healthcheck: RPC up clears the scan marker (#718)" "marker still present"; else ok "healthcheck: RPC up clears the scan marker (#718)"; fi
# RPC down + NO marker (scan already finished once) -> unhealthy: a real fault, not scan tolerance.
mk_curl 7
assert_eq "healthcheck: RPC down after scan done -> unhealthy (#718)" "$(run_hc)" "1"
assert_contains "wallet-entrypoint touches the scan marker on create (#718)" "$(cat "$ROOT/build/monero/wallet-entrypoint.sh")" 'touch "$SCAN_MARKER"'
