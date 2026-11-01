#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-safety.sh
source "$HERE/lib/run-safety.sh"

BASELINE_CONFIG='{"monero":{"mode":"local","view_key":"fixture-monero-view","wallet_address":"fixture-monero-wallet","payout_scan_height":123,"data_dir":"fixture-monero-data"},"tari":{"mode":"local","view_key":"fixture-tari-view","spend_public_key":"fixture-tari-spend","wallet_address":"fixture-tari-wallet","payout_scan_birthday":456,"data_dir":"fixture-tari-data"}}'
original_config="$BASELINE_CONFIG"
REMOTE_MONERO_HOST=monero.example
REMOTE_TARI_HOST=tari.example
REMOTE_MONERO_RPC_PORT=18081
REMOTE_MONERO_ZMQ_PORT=18083
KEEP_STATE=0
BASELINE_SECRET_FP=fixture-secrets

push_config() { applied_config="$1"; }
pithead() {
    assert_eq "teardown applies the original config" "$applied_config" "$original_config"
    assert_eq "teardown uses noninteractive apply" "$*" "apply -y"
    apply_calls=$((apply_calls + 1))
}
wait_status_ok() {
    assert_eq "teardown waits for health with a bound" "$1" 240
    health_calls=$((health_calls + 1))
}
rx() {
    [ "$1" = 'cat config.json' ] || return 1
    printf '%s\n' "$applied_config"
}
secret_fingerprint() { printf '%s\n' fixture-secrets; }

for currency in monero tari; do
    echo "== remote $currency payout inputs and teardown =="
    resolve_overrides "$currency.mode=remote"
    assert_rc "$currency remote overrides resolve" "$?" 0
    # shellcheck disable=SC2086
    rendered="$(render_scenario_config "$BASELINE_CONFIG" $RESOLVED)"
    assert_eq "$currency remote view key is cleared" "$(jq -r --arg c "$currency" '.[$c].view_key' <<<"$rendered")" ""
    if [ "$currency" = tari ]; then
        assert_eq "remote Tari spend public key is cleared" "$(jq -r '.tari.spend_public_key' <<<"$rendered")" ""
        expected="$(jq --arg host "$REMOTE_TARI_HOST" '.tari.mode="remote" | .tari.remote.host=$host | .tari.view_key="" | .tari.spend_public_key=""' <<<"$original_config")"
    else
        expected="$(jq --arg host "$REMOTE_MONERO_HOST" '.monero.mode="remote" | .monero.remote={host:$host,rpc_port:18081,zmq_port:18083} | .monero.view_key=""' <<<"$original_config")"
    fi
    assert_eq "$currency remote preserves all other baseline inputs" "$(jq -cS . <<<"$rendered")" "$(jq -cS . <<<"$expected")"
    assert_eq "$currency rendering leaves the saved baseline intact" "$BASELINE_CONFIG" "$original_config"

    resolve_overrides "monero.mode=local tari.mode=local"
    assert_rc "local overrides resolve after remote $currency" "$?" 0
    # shellcheck disable=SC2086
    local_config="$(render_scenario_config "$BASELINE_CONFIG" $RESOLVED)"
    assert_eq "next local scenario retains both currencies' payout inputs" "$(jq -cS . <<<"$local_config")" "$(jq -cS . <<<"$original_config")"

    applied_config="$rendered"
    apply_calls=0
    health_calls=0
    restore_baseline
    assert_rc "$currency teardown succeeds" "$?" 0
    assert_eq "$currency teardown restores the exact baseline" "$applied_config" "$original_config"
    assert_eq "$currency teardown applies once" "$apply_calls" 1
    assert_eq "$currency teardown checks health once" "$health_calls" 1
done

echo "selftest-remote-payout: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
