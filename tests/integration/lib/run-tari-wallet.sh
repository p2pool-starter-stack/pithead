# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# Tari payout confirmation live leg (#462/#942/#2731): the view-only tari-wallet scans from the
# configured birthday through the LOCAL node only, and the dashboard reports what it found.

# Pure: the remote IPv4 addresses in a /proc/net/tcp body that are not loopback, unspecified or
# private (10/8, 172.16/12, 192.168/16), that is, a connection to a non-local node.
public_remotes_in_proc_tcp() {
    printf '%s\n' "$1" | awk 'function x(s) { return (index("0123456789ABCDEF", substr(s, 1, 1)) - 1) * 16 + index("0123456789ABCDEF", substr(s, 2, 1)) - 1 }
    NR > 1 && $3 ~ /^[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]:/ {
        h = substr($3, 1, 8)
        a = x(substr(h, 7, 2)); b = x(substr(h, 5, 2)); c = x(substr(h, 3, 2)); d = x(substr(h, 1, 2))
        if (a == 0 || a == 127 || a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168)) next
        print a "." b "." c "." d
    }'
}

_pred_tari_payouts_found() {
    local st
    st="$(api_state)"
    [ "$(jq_get "$st" '.earnings.tari_confirmed.count')" -gt 0 ] 2>/dev/null
}

_pred_payout_wallet_ready() { # <confirmed|tari_confirmed>
    local st
    st="$(api_state)"
    [ "$(jq_get "$st" ".earnings.$1.reachable")" = true ] &&
        [ "$(jq_get "$st" ".earnings.$1.address_match")" = true ]
}

# monero-wallet-rpc refuses every call while it catches up after a start (#718, #2756), and the
# wallet's own healthcheck retires this marker only once the wallet reaches monerod's tip.
_pred_monero_wallet_caught_up() {
    # Keep samples in the transcript even when the wallet restarts before final capture.
    wallet_startup_sample || true
    wallet_scan_sample || true
    rx 'docker exec wallet-rpc test ! -e /home/ubuntu/wallets/.payout-scanning' >/dev/null 2>&1
}

assert_payout_wallet_ready() { # <confirmed|tari_confirmed> <Monero|Tari>
    local st
    if [ "$1" = confirmed ]; then
        if wait_for 1200 15 "Monero wallet finishes catching up to monerod (#2498)" _pred_monero_wallet_caught_up; then
            it_pass "Monero payout wallet finished catching up (#2976)"
        else
            it_fail "Monero payout wallet finished catching up (#2976)" "scan marker remains or could not be read after 1200s"
        fi
    fi
    # A scan that failed while the wallet was starting holds reachable=false until the next scan,
    # every 10th dashboard poll (about five minutes), so the wait must outlast one scan cycle.
    wait_for 420 10 "$2 payout wallet reachability and address (#2498)" _pred_payout_wallet_ready "$1" || true
    st="$(api_state)"
    assert_eq "$2 payout wallet answers the dashboard (#2498)" "$(jq_get "$st" ".earnings.$1.reachable")" true
    assert_eq "$2 payout wallet matches the configured address (#2498)" "$(jq_get "$st" ".earnings.$1.address_match")" true
}

assert_tari_payout_scan() { # <config-json> <state-json>
    local config="$1" st="$2" birthday argv node tcp
    assert_eq "TARI_PAYOUT_CONFIRM_ENABLED matches config (#462/#942)" "$(env_on_box TARI_PAYOUT_CONFIRM_ENABLED)" "true"
    assert_eq "dashboard confirms Tari payout tracking is live (#462/#942)" "$(jq_get "$st" '.earnings.tari_confirmed.enabled')" "true"
    # Every process's argv, not PID 1's: the container runs under an init (#2657), so PID 1 is the init.
    argv="$(rx "docker exec tari-wallet sh -c 'cat /proc/[0-9]*/cmdline'" 2>/dev/null | tr '\0' ' ')"
    # The local node is the host of the rendered Tari gRPC address; both scan URLs must name it.
    node="http://$(env_on_box TARI_GRPC_ADDRESS | cut -d: -f1):9000"
    assert_contains "tari-wallet scans through the local node's :9000 (#2731)" "$argv" "-p wallet.http_server_url=$node "
    assert_contains "tari-wallet falls back only to the local node's :9000 (#2731)" "$argv" "-p wallet.fallback_http_server_url=$node "
    case "$argv" in
    *rpc.tari.com*) it_fail "tari-wallet never falls back to the public node (#2731)" "argv names rpc.tari.com" ;;
    *) it_pass "tari-wallet never falls back to the public node (#2731)" ;;
    esac
    birthday="$(jq_get "$config" '.tari.payout_scan_birthday')"
    case "$birthday" in
    '' | auto | *[!0-9]*) it_log "tari birthday is '${birthday:-auto}': no known past payouts to find" ;;
    *)
        assert_contains "tari-wallet scans from the configured birthday (#2731)" "$argv" "--birthday $birthday "
        if wait_for 3600 30 "Tari wallet reports the known past payouts (#2731)" _pred_tari_payouts_found; then
            it_pass "Tari wallet found $(jq_get "$(api_state)" '.earnings.tari_confirmed.count') payouts since birthday $birthday (#2731)"
        else it_fail "Tari wallet found the known past payouts (#2731)" "tari_confirmed.count still 0 after 3600s"; fi
        ;;
    esac
    assert_payout_wallet_ready tari_confirmed Tari
    # Zero grace makes a successful invocation proof of the real image's gRPC probe, not the
    # first-scan allowance. A good probe must also clear the marker permanently.
    if rx 'docker exec -e PAYOUT_SCAN_GRACE_SEC=0 tari-wallet /wallet-config/wallet-healthcheck.sh' >/dev/null 2>&1; then
        it_pass "real Tari wallet gRPC health probe succeeds without scan grace (#2498)"
    else
        it_fail "real Tari wallet gRPC health probe succeeds without scan grace (#2498)" "healthcheck returned nonzero"
    fi
    if rx 'docker exec tari-wallet test ! -e /var/tari/wallet/.payout-scanning' >/dev/null 2>&1; then
        it_pass "real Tari wallet clears the first-scan marker (#2498)"
    else
        it_fail "real Tari wallet clears the first-scan marker (#2498)" "marker remains"
    fi
    # An unreadable socket table must fail the row, never read as "no public peer".
    if ! tcp="$(rx "docker exec tari-wallet cat /proc/net/tcp" 2>/dev/null)" || [[ "$tcp" != *rem_address* ]]; then
        it_fail "tari-wallet holds no connection to a non-local node (#2731)" "could not read the wallet's /proc/net/tcp"
    else
        assert_eq "tari-wallet holds no connection to a non-local node (#2731)" "$(public_remotes_in_proc_tcp "$tcp")" ""
    fi
}
