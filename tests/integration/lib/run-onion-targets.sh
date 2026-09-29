# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
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
    assert_eq "rendered P2Pool port follows $pool sidechain (#2936)" "$onion_pool_port" "$expected_port"
    if rx "docker exec tor grep -Fxq 'HiddenServicePort $onion_pool_port $onion_prefix.28:$onion_pool_port' /tmp/torrc"; then
        it_pass "P2Pool onion forwards the selected $pool port (#2936)"
    else
        it_fail "P2Pool onion forwards the selected $pool port (#2936)" "rendered Tor destination differs"
    fi
    if rx "docker exec tor nc -z -w 3 $onion_prefix.28 $onion_pool_port"; then
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
        if rx "docker exec tor nc -z -w 3 $onion_prefix.26 18084"; then
            it_pass "Tor reaches the Monero anonymous listener (#2936)"
        else
            it_fail "Tor reaches the Monero anonymous listener (#2936)" "TCP probe refused or timed out"
        fi
    fi
}
