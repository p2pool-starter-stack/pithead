#!/usr/bin/env bash
# Exercise the lifecycle proof's real wizard input stream with the runner's baseline contract.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-wizard-defaults.sh
source "$HERE/../lib/run-wizard-defaults.sh"

WORK="$(mktemp -d -t wizard-defaults.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat >"$WORK/bin/df" <<'DF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fixture 999999999 0 %s 1%% %s\n' "$WIZARD_TEST_FREE_KB" "$PWD"
DF
chmod +x "$WORK/bin/df"
echo "== wizard defaults proof uses runner inputs and production shell options =="
IT_PITHEAD="$ROOT/pithead"
# Existing public checksum-valid test fixtures; no live wallet or credentials are read.
monero='48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoD'
tari='126J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5BJ'
BASELINE_CONFIG=$(jq -n --arg m "$monero" --arg t "$tari" '{monero:{wallet_address:$m,data_dir:"fixture-monero"},tari:{wallet_address:$t,data_dir:"fixture-tari"},tor:{data_dir:"fixture-tor"}}')
# Deliberately no BASELINE_JSON: run.sh's preflight only supplies BASELINE_CONFIG.
unset BASELINE_JSON
quote_arg() { printf '%q' "$1"; }
rx() {
    case "$1" in
    *' setup --skip-deps --skip-optimize') printf 'Deployment preparation complete\n' ;;
    *) (cd "$WORK" && PATH="$WORK/bin:$PATH" bash -c "$1" | tee "$WORK/rx.log") ;;
    esac
}
push_config() {
    printf '%s\n' "$1" >"$WORK/config.json"
    if [ "$pushes" -eq 0 ]; then
        cp "$WORK/config.json" "$WORK/generated.json"
    fi
    pushes=$((pushes + 1))
}
pithead() { printf '%s\n' "$*" >>"$WORK/operations"; }
wait_status_ok() { return 0; }
lifecycle_gate_sample() { printf '%s\n' "$1" >>"$WORK/gate-stages"; }

for expected in off local; do
    if [ "$expected" = off ]; then export WIZARD_TEST_FREE_KB=$((100 * 1048576)); else export WIZARD_TEST_FREE_KB=$((600 * 1048576)); fi
    printf 'DEPLOYMENT_COMPLETED=true\n' >"$WORK/.env"
    : >"$WORK/operations"
    : >"$WORK/gate-stages"
    pushes=0
    run_cli_wizard_defaults || {
        sed -E 's/(Generated dashboard password: ).*/\1<redacted>/' "$WORK/rx.log" >&2
        it_fail "wizard defaults harness completed for $expected"
    }
    assert_eq "wizard gate diagnostics cover startup and baseline restore ($expected)" "$(cat "$WORK/gate-stages")" $'after-wizard-up\nbefore-wizard-restore\nafter-wizard-restore-apply'
    generated=$(cat "$WORK/generated.json")
    assert_eq "harness carries the runner's Monero wallet ($expected)" "$(jq -r '.monero.wallet_address' <<<"$generated")" "$monero"
    assert_eq "harness carries disk-derived Tari mode ($expected)" "$(jq -r '.tari.mode' <<<"$generated")" "$expected"
    if [ "$expected" = local ]; then
        assert_eq "harness carries the runner's Tari wallet" "$(jq -r '.tari.wallet_address' <<<"$generated")" "$tari"
    fi
    assert_eq "harness restores the actual runner baseline ($expected)" "$(cat "$WORK/config.json")" "$BASELINE_CONFIG"
    assert_eq "harness preserves prepared chain paths ($expected)" "$(jq -r '[.monero.data_dir,.tari.data_dir,.tor.data_dir] | join("/")' <<<"$generated")" "fixture-monero/fixture-tari/fixture-tor"
    assert_eq "harness deploys defaults then restores ($expected)" "$pushes" 2
    assert_eq "harness runs service startup and baseline apply ($expected)" "$(cat "$WORK/operations")" $'up\napply -y'
done

# Sampling after a refused baseline apply must not replace that command's failure with success
# or run its post-apply healthy-status wait. Keep this deliberate failure isolated.
failed_apply_result=$(
    IT_FAIL=0
    pushes=0
    waits=0
    pithead() { [ "$1" != apply ] || return 17; }
    wait_status_ok() { waits=$((waits + 1)); }
    run_cli_wizard_defaults >/dev/null
    printf '%s|%s' "$IT_FAIL" "$waits"
)
assert_eq "wizard restore diagnostics preserve failed apply and omit its status wait" "$failed_apply_result" '1|1'

# Missing fixture inputs must count a failure before any remote wizard or deployment runs.
missing_result=$(
    BASELINE_CONFIG='{}'
    IT_FAIL=0
    rx() {
        echo 'unexpected remote I/O' >&2
        exit 2
    }
    run_cli_wizard_defaults >/dev/null
    printf '%s|%s' "$?" "$IT_FAIL"
)
assert_eq "missing baseline wallet fails the proof before remote I/O" "$missing_result" '1|1'

echo "selftest-wizard-defaults: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
