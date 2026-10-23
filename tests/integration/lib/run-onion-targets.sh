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

# Probe from outside the stack so a pass proves the real inbound path; exits follow tor-client/probe.sh, 3 on error.
_onion_reachable_external() {
    local onion="${1:-}" saved_env="${2:-}" auth="${3:-auto}" out rc snippet
    [ -n "$onion" ] || onion="$(env_on_box DASHBOARD_ONION_ADDRESS)"
    [ -n "$onion" ] && [ "$onion" != "placeholder" ] || return 2
    printf '%s\n' "$onion" | grep -Eq '^[a-z2-7]{56}\.onion$' || return 3
    rx "docker build -q -t pithead-tor-client-test tests/integration/tor-client/ >/dev/null 2>&1" || return 3
    case "$auth" in
    required)
        [ -z "$saved_env" ] || return 3
        snippet="credential=\$(./pithead onion-client-key 2>/dev/null) || exit 4;"
        snippet="$snippet line=\$(printf '%s\\n' \"\$credential\" | grep -E '^[[:space:]]*$(quote_arg "${onion%.onion}"):descriptor:x25519:[A-Z2-7]+$' | sed 's/^[[:space:]]*//' | head -1);"
        snippet="$snippet [ -n \"\$line\" ] || exit 4;"
        ;;
    none)
        [ -z "$saved_env" ] || return 3
        snippet="line='';"
        ;;
    auto)
        if [ -n "$saved_env" ]; then
            snippet="priv=\$(sudo -n awk -F= '\$1 == \"DASHBOARD_ONION_CLIENT_PRIVKEY\" { print substr(\$0, index(\$0, \"=\") + 1) }' $(quote_arg "$saved_env"));"
            snippet="$snippet [ -n \"\$priv\" ] || exit 4; line=$(quote_arg "${onion%.onion}:descriptor:x25519:")\$priv;"
        else
            snippet="line=\$(./pithead onion-client-key 2>/dev/null | grep -E 'descriptor:x25519:' | head -1 || true);"
        fi
        ;;
    *) return 3 ;;
    esac
    snippet="$snippet if [ -n \"\$line\" ]; then printf '%s\n' \"\$line\" | docker run -i --rm -e ONION_ADDR=$(quote_arg "$onion") -e AUTH_STDIN=1 pithead-tor-client-test;"
    snippet="$snippet else docker run --rm -e ONION_ADDR=$(quote_arg "$onion") pithead-tor-client-test; fi"
    if out="$(rx "$snippet" 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    case "$rc:$out" in
    0:*PROBE-OK:*) return 0 ;;
    1:*PROBE-FAIL:*"HTTP 000"*) return 1 ;;
    2:*PROBE-FAIL:*) return 2 ;;
    4:*)
        [ "$auth" = required ] && return 4
        return 3
        ;;
    *) return 3 ;;
    esac
}
