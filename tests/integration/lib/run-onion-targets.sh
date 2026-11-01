# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
source "${BASH_SOURCE[0]%/*}/onion-baseline-diagnostics.sh" || return $?
# Read the live Tor mapping and dial each local target from Tor's network namespace.
assert_onion_targets() { # <monero mode> <pool name>
    local mode="$1" pool="$2"
    # Probe from Tor's own network namespace. Counting HiddenServiceDir alone cannot show that
    # the separate container can dial the advertised listener (#2936).
    local onion_prefix onion_pool_port expected_port
    case "$pool" in
    main) expected_port=37889 ;;
    mini) expected_port=37888 ;;
    nano) expected_port=37890 ;;
    *)
        it_fail "known P2Pool sidechain for onion probe (#2936)" "unexpected pool type"
        return
        ;;
    esac
    onion_prefix="$(env_on_box NETWORK_PREFIX)"
    onion_pool_port="$(env_on_box P2POOL_PORT)"
    assert_eq "rendered P2Pool port follows selected sidechain (#2936)" "$onion_pool_port" "$expected_port"
    if rx "docker exec tor grep -Fxq 'HiddenServicePort $onion_pool_port $onion_prefix.28:$onion_pool_port' /tmp/torrc"; then
        it_pass "P2Pool onion forwards the selected $pool port (#2936)"
    else
        it_fail "P2Pool onion forwards the selected $pool port (#2936)" "rendered Tor destination differs"
    fi
    # A running container can still be reconnecting to Monero after a subnet restart.
    # Require the advertised listener itself to settle, within the readiness deadline.
    if wait_for 240 5 "P2Pool onion listener (#2936)" rx "docker exec tor nc -z -w 3 $onion_prefix.28 $onion_pool_port"; then
        it_pass "Tor reaches the P2Pool onion target (#2936)"
    else
        it_fail "Tor reaches the P2Pool onion target (#2936)" "TCP probe refused or timed out"
    fi
    if [ "$mode" = "local" ]; then
        if rx "docker exec tor grep -Fxq 'HiddenServicePort 18080 $onion_prefix.26:18084' /tmp/torrc"; then
            it_pass "Monero onion forwards to the local node (#2936)"
        else
            it_fail "Monero onion forwards to the local node (#2936)" "rendered Tor destination differs"
        fi
        if wait_for 240 5 "Monero onion listener (#2936)" rx "docker exec tor nc -z -w 3 $onion_prefix.26 18084"; then
            it_pass "Tor reaches the Monero anonymous listener (#2936)"
        else
            it_fail "Tor reaches the Monero anonymous listener (#2936)" "TCP probe refused or timed out"
        fi
    fi
}

_onion_reachable_external() {
    local onion="${1:-}" saved_env="${2:-}" out rc snippet verdict
    # shellcheck disable=SC2034
    ONION_PROBE_STARTED="$(now_s)"
    [ -n "$onion" ] || onion="$(env_on_box DASHBOARD_ONION_ADDRESS)"
    if [ -z "$onion" ] || [ "$onion" = "placeholder" ]; then
        onion_probe_note input "" ""
        return 2
    fi
    if ! printf '%s\n' "$onion" | grep -Eq '^[a-z2-7]{56}\.onion$'; then
        onion_probe_note input "" ""
        return 3
    fi
    if ! rx "docker build -q -t pithead-tor-client-test tests/integration/tor-client/ >/dev/null 2>&1"; then
        onion_probe_note build "" ""
        return 3
    fi
    if [ -n "$saved_env" ]; then
        snippet="priv=\$(sudo -n awk -F= '\$1 == \"DASHBOARD_ONION_CLIENT_PRIVKEY\" { print substr(\$0, index(\$0, \"=\") + 1) }' $(quote_arg "$saved_env"));"
        snippet="$snippet [ -n \"\$priv\" ] || exit 4; line=$(quote_arg "${onion%.onion}:descriptor:x25519:")\$priv;"
    else
        snippet="line=\$(./pithead onion-client-key 2>/dev/null | grep -E 'descriptor:x25519:' | head -1 || true);"
    fi
    snippet="$snippet if [ -n \"\$line\" ]; then printf '%s\n' \"\$line\" | docker run -i --rm -e ONION_ADDR=$(quote_arg "$onion") -e AUTH_STDIN=1 pithead-tor-client-test;"
    snippet="$snippet else docker run --rm -e ONION_ADDR=$(quote_arg "$onion") pithead-tor-client-test; fi"
    if out="$(rx "$snippet" 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    verdict="$(onion_probe_classify "$rc" "$out")"
    # shellcheck disable=SC2086
    set -- $verdict
    onion_probe_note "$1" "$rc" "${2:-}"
    case "$1" in
    ok) return 0 ;;
    http-reachability) return 1 ;;
    client-bootstrap) return 2 ;;
    *) return 3 ;;
    esac
}
