# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# Block only the dashboard's SOCKS dial in its network namespace: Tor and mining onion peers stay connected.
# Blocking Tor's relay port 443 would also disrupt onions and would not selectively fault HTTPS
# inside Tor's encrypted relay traffic. Same-bridge traffic bypasses the host OUTPUT hook. The
# host egress firewall stays enabled throughout.
tor_probe_ns_ipt() { # <iptables args...>
    rx "p=\$(docker inspect -f '{{.State.Pid}}' dashboard 2>/dev/null); [ \"\${p:-0}\" -gt 0 ] && sudo -n nsenter -t \"\$p\" -n iptables $*" 2>/dev/null
}

_tor_probe_mining_sample() {
    local state accepted workers
    state=$(api_state) || return 1
    accepted=$(jq_get "$state" '.proxy_summary.accepted | gsub(","; "") | tonumber')
    workers=$(jq_get "$state" '.proxy_workers')
    [ -n "$accepted" ] && [ "${workers:-0}" -ge "${EXPECTED_WORKERS:-1}" ] 2>/dev/null || return 1
    printf '%s\n' "$accepted"
}

fault_tor_probe_egress() {
    local prefix epoch tor_before monero_before last now logs i rc=0 rule last_progress=0 mining_failure=
    if [ "$(env_on_box TOR_EGRESS_FIREWALL)" = false ]; then
        it_fail "Tor probe fault requires the egress firewall" "network.tor_egress_firewall=false"
        return
    fi
    if ! wait_for 180 10 "proxy workers online for Tor fault" _tor_probe_mining_sample >/dev/null; then
        it_fail "Tor probe fault has a live mining witness" "proxy shares or workers unavailable"
        return
    fi
    pithead tor-recover check >/dev/null 2>&1 || rc=$?
    assert_ne "ordinary Tor state refused by read-only recovery check" "$rc" "0"
    rx 'bash -c "source ./pithead; dir=\$(tor_recovery_mount) && sudo grep -q . \"\$dir/state\" && tor_recovery_identities \"\$dir\" >/dev/null"' >/dev/null 2>&1
    assert_rc "read-only recovery can inspect the live Tor state and onion identities" "$?" "0"
    rx 'bash -c "source ./pithead && tor_egress_enforced"' >/dev/null 2>&1
    assert_rc "Tor-egress firewall remains enforced before fault" "$?" "0"
    if ! push_config "$(printf '%s' "$BASELINE_CONFIG" | jq '.tor.auto_heal=true')" ||
        ! pithead apply -y >/dev/null 2>&1 || ! wait_status_ok 240; then
        it_fail "Tor probe fault enabled opt-in recovery" "apply or health failed"
        return
    fi
    prefix=$(env_on_box NETWORK_PREFIX)
    tor_before=$(rx "docker inspect tor --format '{{.State.StartedAt}}'")
    monero_before=$(rx "docker inspect monerod --format '{{.State.StartedAt}}'")
    epoch=$(rx 'date +%s')
    last=$(_tor_probe_mining_sample) || {
        it_fail "Tor probe fault has a live mining witness" "proxy shares or workers unavailable"
        return
    }
    rule="-d ${prefix}.25 -p tcp --dport 9050 -m comment --comment pithead-e2e-fault-tor-probe -j DROP"
    if ! tor_probe_ns_ipt "-I OUTPUT $rule" >/dev/null ||
        ! tor_probe_ns_ipt "-C OUTPUT $rule" >/dev/null; then
        it_fail "Tor probe fault installed the dashboard namespace rule" "iptables rule absent"
        tor_probe_ns_ipt "-D OUTPUT $rule" >/dev/null 2>&1 || true
        return
    fi
    it_pass "Tor probe fault blocks dashboard SOCKS traffic in its OUTPUT chain"
    it_step "fault: dashboard Tor SOCKS requests fail while mining onions stay connected…"
    for ((i = 0; i < 25; i++)); do
        sleep 60
        now=$(_tor_probe_mining_sample) || now=
        if [ -z "$now" ]; then
            mining_failure=${mining_failure:-"sample $i had no live proxy worker or accepted-share counter"}
        elif [ "$now" -lt "$last" ]; then
            mining_failure=${mining_failure:-"sample $i reset the proxy accepted-share counter"}
        elif [ "$now" -gt "$last" ]; then
            last=$now
            last_progress=$((i + 1))
        elif [ "$((i + 1 - last_progress))" -ge 5 ]; then
            mining_failure=${mining_failure:-"no accepted share in five minutes by sample $i"}
        fi
    done
    if [ -n "$mining_failure" ]; then
        it_fail "proxy mining continued during Tor clearnet fault" "$mining_failure"
    else
        it_pass "proxy mining continued during Tor clearnet fault"
    fi
    assert_eq "Tor stayed running during circuit refresh" "$(rx "docker inspect tor --format '{{.State.StartedAt}}'")" "$tor_before"
    assert_eq "Monero was not restarted for circuit refresh" "$(rx "docker inspect monerod --format '{{.State.StartedAt}}'")" "$monero_before"
    logs=$(rx "docker logs --since $epoch dashboard 2>&1")
    assert_contains "Tor outage logged two targets and a NEWNYM step" "$logs" "Requesting NEWNYM"
    assert_contains "Tor outage logged corroborating target" "$logs" "cloudflare.com"
    if [ "$(tor_probe_ns_ipt '-L OUTPUT -v -n -x' | awk '/pithead-e2e-fault-tor-probe/ {n += $1} END {print n + 0}')" -gt 0 ]; then
        it_pass "Tor probe fault dropped live dashboard SOCKS packets"
    else
        it_fail "Tor probe fault dropped live dashboard SOCKS packets" "the rule saw no traffic"
    fi
    tor_probe_ns_ipt "-D OUTPUT $rule" >/dev/null 2>&1 || true
    rx 'bash -c "source ./pithead && tor_egress_enforced"' >/dev/null 2>&1
    assert_rc "Tor-egress firewall remains enforced after fault" "$?" "0"
    if wait_for 900 30 "Tor egress recovered after circuit refresh" \
        _tor_probe_recovered "$epoch"; then
        it_pass "Tor egress recovery names the preceding step"
    else
        it_fail "Tor egress recovery names the preceding step" "no corroborated recovery log"
    fi
    push_config "$BASELINE_CONFIG" && pithead apply -y >/dev/null 2>&1 ||
        it_fail "Tor probe fault restored baseline config" "baseline apply failed"
}

_tor_probe_recovered() { # <epoch>
    rx "docker logs --since $1 dashboard 2>&1" | grep -q 'Tor clearnet egress recovered following NEWNYM:'
}

# Lifecycle proves the branch image includes the diagnostic and rejects ordinary healthy Tor.
tor_recovery_healthy_probe() {
    rx 'docker exec tor test -x /usr/local/bin/tor-recovery-diagnose.sh' >/dev/null 2>&1
    assert_rc "Tor image carries the authenticated recovery diagnostic" "$?" "0"
    rx 'docker exec tor /usr/local/bin/tor-recovery-diagnose.sh' >/dev/null 2>&1
    assert_rc "healthy Tor refuses bootstrap-stall recovery diagnosis" "$?" "1"
}
