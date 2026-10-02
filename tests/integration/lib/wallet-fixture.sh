# shellcheck shell=bash
# The outer E2E wrapper owns this private snapshot, separately from public job artifacts.
WALLET_CACHE_SNAPSHOT=""
WALLET_CACHE_IMPORTED=0

wallet_fixture_command() {
    on_bench "python3 - $(quote_arg "$1") $(quote_arg "$RESTORE_DIR") $(quote_arg "$WALLET_CACHE_SNAPSHOT") $(quote_arg "$E2E_DIR")" <"$HERE/lib/wallet-fixture.py"
}

wallet_fixture_receipt() {
    [ -n "${CI_JOB_DIR:-}" ] || return 0
    python3 "$HERE/lib/wallet-fixture.py" receipt "$CI_JOB_DIR" "$1"
}

wallet_fixture_capture() {
    [ "$KEEP" != 1 ] || return 0
    WALLET_CACHE_SNAPSHOT="$(wallet_fixture_command capture)" || die "Prepared wallet cache snapshot failed; branch not deployed."
    [ -n "$WALLET_CACHE_SNAPSHOT" ] || return 0
    wallet_fixture_receipt ARMED || die "Wallet fixture reservation receipt failed; branch not deployed."
    ok "WALLET FIXTURE PRESERVATION ARMED"
}

wallet_fixture_restore() {
    [ -n "$WALLET_CACHE_SNAPSHOT" ] || return 0
    if wallet_fixture_command restore; then
        WALLET_CACHE_IMPORTED=1
        ok "prepared wallet fixture contents restored exactly"
    else
        wallet_fixture_receipt NOT_PROVEN || true
        warn "WALLET FIXTURE RESTORE NOT PROVEN"
        warn "Private wallet snapshot retained at $WALLET_CACHE_SNAPSHOT; leave its reservation held."
        return 1
    fi
}

wallet_fixture_verify() {
    [ -n "$WALLET_CACHE_SNAPSHOT" ] || return 0
    if [ "$WALLET_CACHE_IMPORTED" = 1 ] && (
        # Reuse the original 1200/420-second catch-up, dashboard and address gates.
        # shellcheck disable=SC2034 # lib.sh transport/assertion globals consumed by the reused gate.
        IT_MODE=ssh IT_SSH_DEST="$BENCH_HOST" IT_REMOTE_DIR="$RESTORE_DIR"
        # shellcheck disable=SC2034
        IT_SSH_OPTS=("${SSH_OPTS[@]}")
        # shellcheck disable=SC2034
        INTEGRATION_RUN_SUITE=1 IT_FAIL=0 IT_CURRENT_SCENARIO=wallet-fixture-restore
        # shellcheck source=tests/integration/lib/run-tari-wallet.sh
        source "$HERE/lib/run-tari-wallet.sh" || exit $?
        assert_payout_wallet_ready confirmed Monero
        [ "$IT_FAIL" = 0 ]
    ) && wallet_fixture_receipt READY && wallet_fixture_command cleanup && wallet_fixture_receipt VERIFIED; then
        ok "WALLET FIXTURE RESTORE VERIFIED"
    else
        wallet_fixture_receipt NOT_PROVEN || true
        warn "WALLET FIXTURE RESTORE NOT PROVEN"
        warn "Private wallet snapshot retained at $WALLET_CACHE_SNAPSHOT; leave its reservation held."
        return 1
    fi
}
