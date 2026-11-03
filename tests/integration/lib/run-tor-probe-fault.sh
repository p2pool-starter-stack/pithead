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
    if [ "${SKIP_MINING_ASSERTS:-0}" = "1" ]; then
        it_skip_leg "Tor clearnet probe fault" "no miner attached to this box (--no-mining-asserts)" by-design
        return
    fi
    if [ "$(env_on_box TOR_EGRESS_FIREWALL)" = false ]; then
        it_fail "Tor probe fault requires the egress firewall" "network.tor_egress_firewall=false"
        return
    fi
    fault_rules_clear_all
    if ! wait_for 180 10 "proxy workers online for Tor fault" _tor_probe_mining_sample >/dev/null; then
        it_fail "Tor probe fault has a live mining witness" "proxy shares or workers unavailable"
        return
    fi
    # A saturated history legitimately qualifies for recovery once the heal has recorded a sustained
    # outage (#3052), so name that precondition instead of misreading the accepted check as a defect.
    if rx 'bash -c "source ./pithead; dir=\$(tor_recovery_mount) && tor_recovery_state_saturated \"\$dir/state\""' >/dev/null 2>&1; then
        it_fail "Tor circuit history is ordinary before the fault" "saturated signature already present (CircuitBuildAbandonedCount and TotalBuildTimes at 1000, no CircuitBuildTimeBin); earlier faults in this run left it so"
    else
        pithead tor-recover check >/dev/null 2>&1 || rc=$?
        assert_ne "ordinary Tor state refused by read-only recovery check" "$rc" "0"
    fi
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
    fault_rules_trap_arm
    if ! tor_probe_ns_ipt "-I OUTPUT $rule" >/dev/null ||
        ! tor_probe_ns_ipt "-C OUTPUT $rule" >/dev/null; then
        it_fail "Tor probe fault installed the dashboard namespace rule" "iptables rule absent"
        tor_probe_ns_ipt "-D OUTPUT $rule" >/dev/null 2>&1 || true
        fault_rules_trap_disarm
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
    fault_rules_trap_disarm
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

tor_recovery_lock_snapshot_snippet() {
    cat <<'SNAPSHOT'
set -o pipefail
source ./pithead >/dev/null 2>&1 || exit 1
path=$(mutation_lock_path)
record=$(head -c 256 "$path" 2>/dev/null) || record=
if [[ "$record" =~ ^pid=([0-9]+)\ verb=([a-z-]+)\ since=([0-9TZ:-]+)$ ]]; then
    pid=${BASH_REMATCH[1]} verb=${BASH_REMATCH[2]} since=${BASH_REMATCH[3]}
    case "$verb" in
    up | down | restart | setup | apply | egress-sync | tor-recover | tor-history | tor-newnym | backup | restore | upgrade | reset-dashboard | config-reset | factory-reset | firstboot-install | uninstall | os-update | rotate-secrets) ;;
    *) verb=unknown ;;
    esac
    printf 'lock-record: pid=%s verb=%s since=%s\n' "$pid" "$verb" "$since"
else
    printf '%s\n' 'lock-record: unrecorded'
fi
if ! sudo -n lslocks --notruncate --json --output PID,TYPE,MODE,PATH 2>/dev/null |
    jq -r --arg path "$path" '[.locks[] | select(.path == $path and .type == "FLOCK") |
        select((.pid | type) == "number" and .pid > 0) |
        select(.mode == "WRITE" or .mode == "READ")][:16] |
        if length == 0 then "kernel-lock: none-observed"
        else .[] | "kernel-lock: pid=\(.pid) mode=\(.mode)" end'; then
    printf '%s\n' 'kernel-lock: unavailable'
fi
SNAPSHOT
}

tor_recovery_probe_now_s() {
    python3 -c 'import time; print(int(time.monotonic()))'
}

tor_recovery_healthy_probe() {
    local output='' rc=0 started elapsed attempt=0 snapshot remaining
    local probe_command="${IT_PITHEAD:-./pithead}" IT_PITHEAD
    : >"$OUT_DIR/tor-recovery-admission.log"
    rx 'bash -c "source ./pithead && tor_egress_enforced"' >/dev/null 2>&1
    assert_rc "Tor recovery lifecycle proof keeps the egress firewall enforced" "$?" "0"
    rx 'docker exec tor test -x /usr/local/bin/tor-recovery-diagnose.sh' >/dev/null 2>&1
    assert_rc "Tor image carries the authenticated recovery diagnostic" "$?" "0"
    rx 'docker exec tor /usr/local/bin/tor-recovery-diagnose.sh' >/dev/null 2>&1
    assert_rc "healthy Tor refuses bootstrap-stall recovery diagnosis" "$?" "1"
    started=$(tor_recovery_probe_now_s)
    while :; do
        elapsed=$(($(tor_recovery_probe_now_s) - started))
        remaining=$((60 - elapsed))
        [ "$remaining" -gt 0 ] || break
        IT_PITHEAD="timeout --kill-after=2 $remaining $probe_command"
        rc=0
        attempt=$((attempt + 1))
        output=$(pithead tor-recover check 2>&1) || rc=$?
        elapsed=$(($(tor_recovery_probe_now_s) - started))
        printf 'probe: attempt=%s elapsed_s=%s rc=%s\n' "$attempt" "$elapsed" "$rc" >>"$OUT_DIR/tor-recovery-admission.log"
        if [ "$rc" -eq 1 ] && [[ "$output" == *'Tor recovery refused: circuit history is not saturated.'* ]]; then break; fi
        snapshot=$(rx "timeout --kill-after=1 5 bash -c $(quote_arg "$(tor_recovery_lock_snapshot_snippet)")" 2>/dev/null) || snapshot='kernel-lock: unavailable'
        printf '%s\n' "$snapshot" | grep -E '^(lock-record: (unrecorded|pid=[0-9]+ verb=(up|down|restart|setup|apply|egress-sync|tor-recover|tor-history|tor-newnym|backup|restore|upgrade|reset-dashboard|config-reset|factory-reset|firstboot-install|uninstall|os-update|rotate-secrets|unknown) since=[0-9TZ:-]+)|kernel-lock: (none-observed|unavailable|pid=[0-9]+ mode=(WRITE|READ)))$' |
            head -n 17 >>"$OUT_DIR/tor-recovery-admission.log"
        [ "$rc" -eq 75 ] || break
        elapsed=$(($(tor_recovery_probe_now_s) - started))
        [ "$elapsed" -lt 60 ] || break
        sleep 2
    done
    printf 'admission: elapsed_s=%s rc=%s\n' "$(($(tor_recovery_probe_now_s) - started))" "$rc" >>"$OUT_DIR/tor-recovery-admission.log"
    assert_rc "healthy Tor recovery check exits 1 (#3262)" "$rc" "1"
    assert_contains "healthy Tor recovery check names its guard (#3262)" "$output" "Tor recovery refused: circuit history is not saturated."
    if [[ "$output" = *"aborted unexpectedly"* || "$output" = *"bash -x"* ]]; then
        it_fail "healthy Tor recovery refusal omits unexpected-abort advice (#3262)" "$output"
    else
        it_pass "healthy Tor recovery refusal omits unexpected-abort advice (#3262)"
    fi
}
