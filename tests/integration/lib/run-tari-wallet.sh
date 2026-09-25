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

assert_tari_payout_scan() { # <config-json> <state-json>
    local config="$1" st="$2" birthday argv
    assert_eq "TARI_PAYOUT_CONFIRM_ENABLED matches config (#462/#942)" "$(env_on_box TARI_PAYOUT_CONFIRM_ENABLED)" "true"
    assert_eq "dashboard confirms Tari payout tracking is live (#462/#942)" "$(jq_get "$st" '.earnings.tari_confirmed.enabled')" "true"
    argv="$(rx "docker exec tari-wallet cat /proc/1/cmdline" 2>/dev/null | tr '\0' ' ')"
    assert_contains "tari-wallet fallback node is the local node's :9000 (#2731)" "$argv" "wallet.fallback_http_server_url=http://"
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
    assert_eq "tari-wallet holds no connection to a non-local node (#2731)" \
        "$(public_remotes_in_proc_tcp "$(rx "docker exec tari-wallet cat /proc/net/tcp" 2>/dev/null)")" ""
}
