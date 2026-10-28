#!/usr/bin/env bash
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
export WIZARD_TEST_CLI="$ROOT/pithead"
IT_PITHEAD="$WORK/pithead"
cat >"$IT_PITHEAD" <<'CLI'
#!/usr/bin/env bash
source "${WIZARD_TEST_CLI:?}"
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf '%s\n' "$*" >>operations
    case "$1" in
    up | restart) print_first_run_epilogue ;;
    *) exit 97 ;;
    esac
fi
CLI
chmod +x "$IT_PITHEAD"
monero='48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoD'
tari='126J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5BJ'
BASELINE_CONFIG=$(jq -n --arg m "$monero" --arg t "$tari" '{monero:{wallet_address:$m,data_dir:"fixture-monero"},tari:{wallet_address:$t,data_dir:"fixture-tari"},tor:{data_dir:"fixture-tor"},p2pool:{pool:"mini"}}')
ENTRY_CONFIG=$(jq '.p2pool.pool = "main" | .dashboard.tari_required = true' <<<"$BASELINE_CONFIG")
unset BASELINE_JSON
quote_arg() { printf '%q' "$1"; }
rx() {
    case "${WIZARD_FAILURE:-}:$1" in
    entry-read-fails:'cat config.json' | env-fails:*'DEPLOYMENT_COMPLETED=false'* | startup-fails:*'test ! -e .itest-first-run-done'*) return 17 ;;
    setup-fails:*' setup --skip-deps --skip-optimize') return 17 ;;
    esac
    case "$1" in
    *' setup --skip-deps --skip-optimize')
        printf 'TARI_REQUIRED=false\n' >>"$WORK/.env"
        printf 'Deployment preparation complete\n'
        ;;
    *) (cd "$WORK" && PATH="$WORK/bin:$PATH" bash -c "$1" | tee "$WORK/rx.log") ;;
    esac
}
push_config() {
    [ "${WIZARD_FAILURE:-}:$pushes" != restore-push-fails:1 ] || return 17
    printf '%s\n' "$1" >"$WORK/config.json"
    if [ "$pushes" -eq 0 ]; then
        cp "$WORK/config.json" "$WORK/generated.json"
    fi
    pushes=$((pushes + 1))
    [ "${WIZARD_FAILURE:-}:$pushes" != initial-push-fails:1 ] || return 17
}
pithead() {
    printf '%s\n' "$*" >>"$WORK/operations"
    [ "${WIZARD_FAILURE:-}:$1" != restore-apply-fails:apply ]
}
wait_status_ok() {
    waits=$((waits + 1))
    [ "${WIZARD_FAILURE:-}:$waits" != health-fails:1 ] && [ "${WIZARD_FAILURE:-}:$waits" != restore-health-fails:2 ]
}
lifecycle_gate_sample() { printf '%s\n' "$1" >>"$WORK/gate-stages"; }

expected=local
for free_gib in 100 600; do
    export WIZARD_TEST_FREE_KB=$((free_gib * 1048576))
    expected="local ${free_gib}G"
    printf 'DEPLOYMENT_COMPLETED=true\n' >"$WORK/.env"
    : >"$WORK/operations"
    : >"$WORK/gate-stages"
    pushes=0 waits=0
    printf '%s\n' "$ENTRY_CONFIG" >"$WORK/config.json"
    if [ "$free_gib" = 600 ]; then printf 'original marker\n' >"$WORK/.pithead-first-run-done"; fi
    run_cli_wizard_defaults || {
        sed -E 's/(Generated dashboard password: ).*/\1<redacted>/' "$WORK/rx.log" >&2
        it_fail "wizard defaults harness completed for $expected"
    }
    assert_eq "wizard gate diagnostics cover startup and entry restore ($expected)" "$(cat "$WORK/gate-stages")" $'after-wizard-up\nbefore-wizard-restore\nafter-wizard-restore-apply'
    generated=$(cat "$WORK/generated.json")
    assert_eq "harness carries the runner's Monero wallet ($expected)" "$(jq -r '.monero.wallet_address' <<<"$generated")" "$monero"
    assert_eq "harness answers the Tari question explicitly, whatever the disk ($expected)" "$(jq -r '.tari.mode' <<<"$generated")" "local"
    assert_eq "harness carries the runner's Tari wallet ($expected)" "$(jq -r '.tari.wallet_address' <<<"$generated")" "$tari"
    assert_eq "harness writes tari_required false for the Tari yes ($expected)" "$(jq -r '.dashboard.tari_required' <<<"$generated")" "false"
    assert_eq "harness restores the differing entry configuration ($expected)" "$(cat "$WORK/config.json")" "$ENTRY_CONFIG"
    assert_eq "harness preserves prepared chain paths ($expected)" "$(jq -r '[.monero.data_dir,.tari.data_dir,.tor.data_dir] | join("/")' <<<"$generated")" "fixture-monero/fixture-tari/fixture-tor"
    assert_eq "harness deploys defaults then restores ($expected)" "$pushes" 2
    assert_eq "harness runs service startup and entry apply ($expected)" "$(cat "$WORK/operations")" $'up\nrestart\napply -y'
    if [ "$free_gib" = 600 ]; then
        assert_eq "first-start probe preserves the original marker" "$(cat "$WORK/.pithead-first-run-done")" "original marker"
    else
        if [ -e "$WORK/.pithead-first-run-done" ]; then
            it_fail "first-start probe restores an absent marker"
        else
            it_pass "first-start probe restores an absent marker"
        fi
    fi
    if [ -e "$WORK/.itest-first-run-done" ]; then
        it_fail "first-start probe removes its saved-marker fixture ($expected)"
    else
        it_pass "first-start probe removes its saved-marker fixture ($expected)"
    fi
done

remote_baseline=$(jq -c '.monero += {mode:"remote",remote_host:"fixture-node"} | .tari += {mode:"remote",remote_host:"fixture-node"}' <<<"$BASELINE_CONFIG")
remote_result=$(
    BASELINE_CONFIG=$remote_baseline
    IT_FAIL=0
    pushes=0 waits=0
    printf '%s\n' "$remote_baseline" >"$WORK/config.json"
    : >"$WORK/operations"
    run_cli_wizard_defaults >/dev/null
    printf '%s|%s' "$IT_FAIL" "$(jq -c '[.monero.mode, .monero.remote_host, .tari.mode, .dashboard.auth.password != null]' "$WORK/generated.json")"
)
assert_eq "a remote-node baseline keeps its node sections and the wizard's dashboard choices" "$remote_result" '0|["remote","fixture-node","remote",true]'

wizard_failure_result() {
    (
        WIZARD_FAILURE="$1" IT_FAIL=0 pushes=0 waits=0
        printf 'DEPLOYMENT_COMPLETED=true\n' >"$WORK/.env"
        printf '%s\n' "$ENTRY_CONFIG" >"$WORK/config.json"
        case "$WIZARD_FAILURE" in
        entry-empty) : >"$WORK/config.json" ;;
        entry-invalid) printf '[]' >"$WORK/config.json" ;;
        esac
        : >"$WORK/operations"
        run_cli_wizard_defaults >/dev/null
        result_rc=$?
        restored=no applied=no failed=no
        [ "$(cat "$WORK/config.json")" != "$ENTRY_CONFIG" ] || restored=yes
        ! grep -qx 'apply -y' "$WORK/operations" || applied=yes
        [ "$IT_FAIL" -eq 0 ] || failed=yes
        printf '%s|%s|%s|%s|%s' "$result_rc" "$failed" "$restored" "$applied" "$waits"
    )
}
for failure in initial-push-fails env-fails setup-fails startup-fails; do
    assert_eq "wizard $failure restores its entry configuration before returning failure" \
        "$(wizard_failure_result "$failure")" '1|yes|yes|yes|1'
done
assert_eq "an unhealthy wizard trial restores its entry configuration" \
    "$(wizard_failure_result health-fails)" '1|yes|yes|yes|2'
assert_eq "a refused restore push fails without applying or waiting on it" \
    "$(wizard_failure_result restore-push-fails)" '1|yes|no|no|1'
assert_eq "a refused restore apply fails and omits its healthy-status wait" \
    "$(wizard_failure_result restore-apply-fails)" '1|yes|yes|yes|1'
assert_eq "an unhealthy entry restoration fails the wizard proof" \
    "$(wizard_failure_result restore-health-fails)" '1|yes|yes|yes|2'
assert_eq "an unreadable entry config refuses before any fixture push" \
    "$(wizard_failure_result entry-read-fails)" '1|yes|yes|no|0'

for failure in entry-empty entry-invalid; do
    assert_eq "an invalid entry config refuses before any fixture push ($failure)" \
        "$(wizard_failure_result "$failure")" '1|yes|no|no|0'
done

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
