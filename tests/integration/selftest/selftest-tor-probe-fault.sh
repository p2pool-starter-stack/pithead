#!/usr/bin/env bash
# Pure regression fixtures: no remote command or real wait runs here.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/fault-rules.sh
source "$HERE/../lib/fault-rules.sh"
# shellcheck source=tests/integration/lib/run-tor-probe-fault.sh
source "$HERE/../lib/run-tor-probe-fault.sh"
has_compose_profile() { return 1; }

SCRATCH=$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:-${TMP:-/tmp}}}/tor-probe-selftest.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd -P)
trap 'rm -rf "$SCRATCH"' EXIT
PASS=0
FAIL=0
check() {
    if "$@"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n' "$*" >&2
    fi
}

echo "== Mining witness samples retain bounded numeric context without identifiers =="
(
    api_state() {
        printf '%s\n' '{"proxy_summary":{"accepted":"1,201"},"proxy_workers":1,"workers":[{"h60":22000,"uptime":600,"name":"fixture-private-identifier"}]}'
    }
    check test "$(_tor_probe_mining_sample 7 2>"$SCRATCH/sample")" = 1201
    check grep -q '^Tor mining sample 7: ' "$SCRATCH/sample"
    check jq -e '.accepted == 1201 and .workers == 1 and .worker_h60 == 22000 and .worker_uptime_min == 600' < <(sed 's/^Tor mining sample 7: //' "$SCRATCH/sample")
    check test "$(wc -l <"$SCRATCH/sample" | tr -d ' ')" = 1
    if grep -q 'fixture-private-identifier' "$SCRATCH/sample"; then exit 1; fi
    api_state() { return 1; }
    if _tor_probe_mining_sample 8 >"$SCRATCH/count" 2>"$SCRATCH/sample-error"; then exit 1; fi
    check grep -qx 'Tor mining sample 8: API unavailable' "$SCRATCH/sample-error"
    check test ! -s "$SCRATCH/count"
    test "$FAIL" -eq 0
)

echo "== A stalled witness names the same one-based sample as its diagnostics =="
(
    SKIP_MINING_ASSERTS=0 EXPECTED_WORKERS=1 BASELINE_CONFIG='{}' OUT_DIR="$SCRATCH/evidence"
    api_state() { printf '%s\n' '{"proxy_summary":{"accepted":"1201"},"proxy_workers":1}'; }
    env_on_box() {
        case "$1" in
        TOR_EGRESS_FIREWALL) echo true ;;
        DASHBOARD_CONTROL_ENABLED) echo false ;;
        NETWORK_PREFIX) echo 192.0.2 ;;
        esac
    }
    fault_rules_clear_all() { :; }
    fault_rules_trap_arm() { :; }
    fault_rules_trap_disarm() { :; }
    push_config() {
        if [ -e "$SCRATCH/tor-fault-started" ]; then
            grep -q 'Tor clearnet egress recovered following NEWNYM:' "$OUT_DIR/tor-probe-fault/dashboard.log"
        fi
    }
    wait_status_ok() { :; }
    wait_for() {
        shift 3
        "$@"
    }
    sleep() { touch "$SCRATCH/tor-fault-started"; }
    pithead() { [ "$*" != 'tor-recover check' ]; }
    tor_probe_ns_ipt() {
        if [[ "$*" = '-L '* ]]; then echo '1 pithead-e2e-fault-tor-probe'; fi
    }
    rx() {
        case "$*" in
        *tor_recovery_state_saturated*) return 1 ;;
        *'docker inspect tor'* | *'docker inspect monerod'*) echo unchanged ;;
        'date +%s') echo 100 ;;
        *'docker logs --since'*) echo 'Requesting NEWNYM cloudflare.com Tor clearnet egress recovered following NEWNYM:' ;;
        esac
    }
    fault_tor_probe_egress >"$SCRATCH/stalled-run" 2>"$SCRATCH/stalled-samples"
    check test -s "$OUT_DIR/tor-probe-fault/dashboard.log"
    check test "$IT_FAIL" -eq 1
    check grep -q 'no accepted share in five minutes by sample 5' "$SCRATCH/stalled-run"
    check grep -q '^Tor mining sample 5: ' "$SCRATCH/stalled-samples"
    test "$FAIL" -eq 0
)

echo "== A failed healer log read remains explicit evidence =="
(
    OUT_DIR="$SCRATCH/failed-read"
    rx() {
        [ "$*" = 'timeout 30 docker logs --since 100 --tail 2000 dashboard 2>&1' ] || exit 17
        return 124
    }
    _tor_probe_capture 100
    check grep -qx 'Tor healer log read failed' "$OUT_DIR/tor-probe-fault/dashboard.log"
    test "$FAIL" -eq 0
    mkdir() { return 1; }
    _tor_probe_capture 100 >"$SCRATCH/directory-failure" 2>&1
    check grep -q 'Tor healer evidence directory unavailable' "$SCRATCH/directory-failure"
    test "$FAIL" -eq 0
)

echo "== Tor probe fault skips before any live work when mining assertions are disabled =="
(
    SKIP_MINING_ASSERTS=1
    # A file records calls even inside command substitutions.
    unexpected() {
        echo "$1" >>"$SCRATCH/live-calls"
        return 1
    }
    env_on_box() {
        unexpected env_on_box
        echo false
    }
    wait_for() { unexpected wait_for; }
    rx() { unexpected rx; }
    push_config() { unexpected push_config; }
    pithead() { unexpected pithead; }
    _tor_probe_mining_sample() { unexpected mining_sample; }
    fault_tor_probe_egress
    check test ! -e "$SCRATCH/live-calls"
    check test "$IT_FAIL" -eq 0
    check test "$IT_PASS" -eq 0
    check test "$IT_SKIPPED_LEGS" -eq 1
    check test "$IT_SKIPPED_BY_DESIGN" -eq 1
    check test "$IT_SKIPPED_MISSING" -eq 0
    check test "$IT_SKIPPED_COVERED" -eq 0
    check test "$IT_SKIPPED_PHASES" -eq 0
    check test "$IT_SKIPPED" -eq 0
    check grep -Fq 'Tor clearnet probe fault' <<<"$IT_SKIPPED_NAMES"
    check grep -Fq -- '--no-mining-asserts' <<<"$IT_SKIPPED_NAMES"
    check grep -Fq 'no miner attached' <<<"$IT_SKIPPED_NAMES"
    printf 'skip fixture: %s passed, %s failed\n' "$PASS" "$FAIL"
    test "$FAIL" -eq 0
)

echo "== Missing mining witnesses remain failures without the explicit skip =="
for flag in 0 unset; do
    (
        if [ "$flag" = unset ]; then unset SKIP_MINING_ASSERTS; else SKIP_MINING_ASSERTS=$flag; fi
        waited=0
        OUT_DIR="$SCRATCH/binding-$flag"
        mkdir -p "$OUT_DIR"
        api_state() { echo '{"proxy_workers":0}'; }
        env_on_box() { echo true; }
        cleared=0
        fault_rules_clear_all() { cleared=$((cleared + 1)); }
        tor_newnym_budget_reset() { budget_reset=$((${budget_reset:-0} + 1)); }
        wait_for() {
            check test "$budget_reset" -eq 1
            check test "$1" -eq 180
            check test "$cleared" -eq 1
            check test "$2" -eq 10
            check test "$4" = _tor_probe_mining_sample
            waited=$((waited + 1))
            return 1
        }
        fault_tor_probe_egress
        check test "$waited" -eq 1
        check test "$IT_FAIL" -eq 1
        check test "$IT_PASS" -eq 0
        check test "$IT_SKIPPED_LEGS" -eq 0
        check grep -Fq 'Tor probe fault has a live mining witness' <<<"$IT_FAILED_NAMES"
        check grep -Fq 'before-fault' "$OUT_DIR/tor-probe-witness.log"
        printf 'binding fixture (%s): %s passed, %s failed\n' "$flag" "$PASS" "$FAIL"
        test "$FAIL" -eq 0
    )
done

echo "== A peerless Monero node fails the precondition before any fault is installed =="
(
    env_on_box() { echo true; }
    has_compose_profile() { return 0; }
    fault_rules_clear_all() { :; }
    tor_newnym_budget_reset() { :; }
    waits=""
    wait_for() {
        waits="$waits $1"
        [ "$1" -eq 180 ] || return 1
    }
    rx() { echo "unexpected rx" >>"$SCRATCH/peerless-calls"; }
    push_config() { echo "unexpected push_config" >>"$SCRATCH/peerless-calls"; }
    fault_tor_probe_egress
    check test "$waits" = " 180 600"
    check test "$IT_FAIL" -eq 1
    check test ! -e "$SCRATCH/peerless-calls"
    check grep -Fq 'Tor probe fault starts with Tor carrying peer traffic' <<<"$IT_FAILED_NAMES"
    printf 'peerless fixture: %s passed, %s failed\n' "$PASS" "$FAIL"
    test "$FAIL" -eq 0
)
echo "== Failed mining and recovery rows carry the dashboard's own log lines =="
(
    BASELINE_CONFIG='{}' OUT_DIR="$SCRATCH/dashboard-lines"
    env_on_box() { echo true; }
    fault_rules_clear_all() { :; }
    fault_rules_trap_arm() { :; }
    fault_rules_trap_disarm() { :; }
    tor_newnym_budget_reset() { :; }
    push_config() { :; }
    pithead() { :; }
    wait_status_ok() { :; }
    sleep() { :; }
    wait_for() {
        case "$4" in
        _tor_probe_mining_sample) return 0 ;;
        _tor_probe_witness_latch) TOR_PROBE_LAST=5 ;;
        *) return 1 ;;
        esac
    }
    _tor_probe_mining_sample() { return 1; }
    DASHBOARD_LOG="$SCRATCH/dashboard.log"
    export DASHBOARD_LOG
    printf '%s\n' \
        '2026-11-22 10:00:17,201 [WARNING] Mining work is not valid (Monero node unreachable past the debounce) — stopping xmrig-proxy so workers fail over to their backup pools.' \
        '2026-11-22 10:04:02,917 [WARNING] Tor clearnet egress failed for 5 minutes: check.torproject.org and cloudflare.com timed out. Requesting NEWNYM (1/2).' \
        "2026-11-22 10:20:40,005 [WARNING] Tor clearnet egress is STILL broken after 2 recovery attempts (0 disruptive in the last day, cap 2): probe timeout. No more automatic action; run './pithead doctor' for current evidence." >"$DASHBOARD_LOG"
    rx() {
        case "$1" in
        "docker logs --since 1 dashboard 2>&1"*) bash -c "cat \"\$DASHBOARD_LOG\"${1#docker logs --since 1 dashboard 2>&1}" ;;
        *tor_recovery_state_saturated*) return 1 ;;
        *) echo 1 ;;
        esac
    }
    fault_tor_probe_egress >"$SCRATCH/dashboard-detail.out"
    check grep -Fq 'sample 1 had no live proxy worker or accepted-share counter; dashboard: 2026-11-22 10:00:17,201 [WARNING] Mining work is not valid (Monero node unreachable past the debounce) — stopping xmrig-proxy' "$SCRATCH/dashboard-detail.out"
    check grep -Fq 'no corroborated recovery log; last dashboard Tor lines: 2026-11-22 10:04:02,917 [WARNING] Tor clearnet egress failed for 5 minutes' "$SCRATCH/dashboard-detail.out"
    check grep -q '^2026-11-22 10:20:40,005 \[WARNING\] Tor clearnet egress is STILL broken after 2 recovery attempts' "$SCRATCH/dashboard-detail.out"
    printf 'dashboard detail fixture: %s passed, %s failed\n' "$PASS" "$FAIL"
    test "$FAIL" -eq 0
)
echo "== Post-apply witness waits for a reconnecting proxy and records the state when none qualifies =="
for fixture in reconnects never; do
    (
        IT_FAIL=0 IT_PASS=0 IT_FAILED_NAMES=
        OUT_DIR="$SCRATCH/witness-$fixture"
        mkdir -p "$OUT_DIR"
        EXPECTED_WORKERS=1
        SKIP_MINING_ASSERTS=0
        reads="$OUT_DIR/reads"
        : >"$reads"
        api_state() {
            echo read >>"$reads"
            if [ "$fixture" = reconnects ] && [ "$(wc -l <"$reads")" -ge 4 ]; then
                echo '{"proxy_workers":1,"proxy_summary":{"accepted":"1,234"}}'
            else
                echo '{"proxy_workers":0,"proxy_summary":{},"workers":[{"name":"rig-a","status":"offline","uptime":0,"accepted":159,"ip":"192.0.2.9"}]}'
            fi
        }
        env_on_box() { echo true; }
        fault_rules_clear_all() { :; }
        fault_rules_trap_arm() { :; }
        fault_rules_trap_disarm() { :; }
        rx() { return 0; }
        push_config() { :; }
        wait_status_ok() { :; }
        tor_probe_ns_ipt() { return 1; }
        pithead() { [ "$1" = apply ]; }
        wait_for() {
            local tries=$1 desc=$3
            shift 3
            [[ "$desc" == *"for Tor fault"* ]] && return 0
            while [ "$tries" -gt 0 ]; do
                "$@" && return 0
                tries=$((tries - 10))
            done
            return 1
        }
        BASELINE_CONFIG='{}'
        fault_tor_probe_egress >/dev/null
        if [ "$fixture" = reconnects ]; then
            check test "$(wc -l <"$reads")" -eq 4
            check test "$TOR_PROBE_LAST" = 1234
            check test "$(grep -c 'live mining witness' <<<"$IT_FAILED_NAMES")" -eq 0
            check grep -Fq 'installed the dashboard namespace rule' <<<"$IT_FAILED_NAMES"
            check test ! -e "$OUT_DIR/tor-probe-witness.log"
        else
            check test "$(wc -l <"$reads")" -eq 7
            check grep -Fq 'Tor probe fault has a live mining witness' <<<"$IT_FAILED_NAMES"
            check grep -Fq 'after-apply' "$OUT_DIR/tor-probe-witness.log"
            check grep -Fq '"proxy_workers":0' "$OUT_DIR/tor-probe-witness.log"
            check grep -Fq '"workers":[{"name":"rig-a","status":"offline","uptime":0,"accepted":159}]' "$OUT_DIR/tor-probe-witness.log"
            check test "$(grep -c 192.0.2.9 "$OUT_DIR/tor-probe-witness.log")" -eq 0
        fi
        printf 'witness fixture (%s): %s passed, %s failed\n' "$fixture" "$PASS" "$FAIL"
        test "$FAIL" -eq 0
    )
done

echo "== Lifecycle recovery proof rejects false success and unexpected-abort advice =="
for fixture in clears refusal abort success wrong-guard busy error deadline sampler-timeout slow-check; do
    (
        IT_FAIL=0 IT_PASS=0
        OUT_DIR="$SCRATCH/$fixture"
        mkdir -p "$OUT_DIR"
        clock=0
        now_s() { echo 9999999999; }
        tor_recovery_probe_now_s() { echo $((clock + $(cat "$OUT_DIR/skew" 2>/dev/null || echo 0))); }
        sleep() { clock=$((clock + $1)); }
        rx() {
            if [[ "$1" == *lslocks* ]]; then
                printf '%s\n' "$1" >"$OUT_DIR/sampler-command"
                [ "$fixture" != sampler-timeout ] || return 124
                printf '%s\n' 'lock-record: pid=42 verb=apply since=2026-10-31T00:00:00Z' 'kernel-lock: pid=42 mode=WRITE' 'untrusted diagnostic payload'
                return 0
            fi
            if [[ "$1" == *tor-control-signal.sh* ]]; then
                echo 'circuit-established=0 pending=70'
                return 0
            fi
            [ "$1" != 'docker exec tor /usr/local/bin/tor-recovery-diagnose.sh' ]
        }
        pithead() {
            printf '%s|%s\n' "$((150 - clock))" "${IT_PITHEAD:-./pithead}" >>"$OUT_DIR/commands"
            echo attempt >>"$OUT_DIR/calls"
            case "$fixture" in
            busy | clears | sampler-timeout)
                if [ "$fixture" = busy ] || [ "$(wc -l <"$OUT_DIR/calls")" -lt 3 ]; then
                    echo 'Timed out waiting for another pithead operation (holder unrecorded)'
                    return 75
                fi
                echo '[WARNING] Tor recovery refused: circuit history is not saturated.'
                return 1
                ;;
            error) return 2 ;;
            slow-check)
                remaining=${IT_PITHEAD#timeout --kill-after=2 }
                remaining=${remaining%% *}
                [ "$remaining" -ge 100 ] || return 124
                echo 100 >"$OUT_DIR/skew"
                echo '[WARNING] Tor recovery refused: circuit history is not saturated.'
                return 1
                ;;
            deadline) return 124 ;;
            refusal)
                echo '[WARNING] Tor recovery refused: circuit history is not saturated.'
                return 1
                ;;
            abort)
                echo '[WARNING] Tor recovery refused: circuit history is not saturated.'
                echo 'pithead aborted unexpectedly; bash -x'
                return 1
                ;;
            success) echo '[WARNING] Tor recovery refused: circuit history is not saturated.' ;;
            wrong-guard)
                echo 'Tor recovery refused: data mount is ambiguous.'
                return 1
                ;;
            esac
        }
        set +e
        tor_recovery_healthy_probe
        set -e
        if [ "$fixture" = refusal ] || [ "$fixture" = clears ] || [ "$fixture" = sampler-timeout ] || [ "$fixture" = slow-check ]; then
            check test "$IT_FAIL" -eq 0
            check test "$IT_PASS" -eq 6
        elif [ "$fixture" = busy ] || [ "$fixture" = error ] || [ "$fixture" = deadline ]; then
            check test "$IT_FAIL" -eq 2
        else
            check test "$IT_FAIL" -eq 1
        fi
        while IFS='|' read -r remaining command; do
            check test "$command" = "timeout --kill-after=2 $remaining ./pithead"
        done <"$OUT_DIR/commands"
        if [ -f "$OUT_DIR/sampler-command" ]; then
            check grep -q '^timeout --kill-after=1 5 bash -c ' "$OUT_DIR/sampler-command"
        fi
        case "$fixture" in
        clears)
            check test "$(wc -l <"$OUT_DIR/calls")" -eq 3
            check grep -q 'elapsed_s=4 rc=1' "$OUT_DIR/tor-recovery-admission.log"
            check grep -q 'rc=75' "$OUT_DIR/tor-recovery-admission.log"
            check grep -q 'kernel-lock: pid=42 mode=WRITE' "$OUT_DIR/tor-recovery-admission.log"
            check grep -q '^lock-record: pid=42 verb=apply since=2026-10-31T00:00:00Z$' "$OUT_DIR/tor-recovery-admission.log"
            check test "$(grep -c 'untrusted' "$OUT_DIR/tor-recovery-admission.log")" -eq 0
            ;;
        busy)
            check test "$clock" -eq 150
            check test "$(wc -l <"$OUT_DIR/calls")" -eq 75
            check grep -q 'admission: elapsed_s=150 rc=75' "$OUT_DIR/tor-recovery-admission.log"
            ;;
        sampler-timeout)
            check test "$(wc -l <"$OUT_DIR/calls")" -eq 3
            check grep -q '^kernel-lock: unavailable$' "$OUT_DIR/tor-recovery-admission.log"
            ;;
        slow-check)
            check test "$(wc -l <"$OUT_DIR/calls")" -eq 1
            check grep -q 'elapsed_s=100 rc=1' "$OUT_DIR/tor-recovery-admission.log"
            check test "$(grep -c '^tor-status:' "$OUT_DIR/tor-recovery-admission.log")" -eq 0
            ;;
        deadline)
            check test "$(wc -l <"$OUT_DIR/calls")" -eq 1
            check grep -q '^tor-status: circuit-established=0 pending=70$' "$OUT_DIR/tor-recovery-admission.log"
            check grep -q 'kernel-lock: pid=42 mode=WRITE' "$OUT_DIR/tor-recovery-admission.log"
            ;;
        *) check test "$(wc -l <"$OUT_DIR/calls")" -eq 1 ;;
        esac
        printf 'recovery fixture (%s): %s passed, %s failed\n' "$fixture" "$PASS" "$FAIL"
        test "$FAIL" -eq 0
    )
done

echo "== Lock snapshot projects bounded identity fields without paths or command arguments =="
mkdir -p "$SCRATCH/bin" "$SCRATCH/target"
cat >"$SCRATCH/target/pithead" <<'CLI'
set -Eeuo pipefail
mutation_lock_path() { printf '%s/.pithead.lock' "$PWD"; }
CLI
cat >"$SCRATCH/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
shift
exec "$@"
SUDO
cat >"$SCRATCH/bin/lslocks" <<'LOCKS'
#!/usr/bin/env bash
cat "$LOCKS_JSON"
exit "${LOCKS_RC:-0}"
LOCKS
chmod +x "$SCRATCH/bin/"*
export LOCKS_JSON="$SCRATCH/locks.json"
jq -n --arg path "$SCRATCH/target/.pithead.lock" '{locks: [
    {pid: 42, type: "FLOCK", mode: "WRITE", path: $path, command: "private-argument"},
    {pid: 43, type: "FLOCK", mode: "WRITE", path: "unrelated-private-path"}
]}' >"$LOCKS_JSON"
for record in 'pid=42 verb=apply since=2026-10-31T00:00:00Z' 'pid=42 verb=private-host since=2026-10-31T00:00:00Z' 'host-path-and-credential'; do
    printf '%s\n' "$record" >"$SCRATCH/target/.pithead.lock"
    out=$(cd "$SCRATCH/target" && PATH="$SCRATCH/bin:$PATH" bash -c "$(tor_recovery_lock_snapshot_snippet)")
    check grep -q '^kernel-lock: pid=42 mode=WRITE$' <<<"$out"
    check test "$(printf '%s' "$out" | wc -l)" -eq 1
    case "$record" in
    *verb=apply*) check grep -q '^lock-record: pid=42 verb=apply since=2026-10-31T00:00:00Z$' <<<"$out" ;;
    *verb=private-host*) check grep -q 'verb=unknown' <<<"$out" ;;
    *) check grep -q '^lock-record: unrecorded$' <<<"$out" ;;
    esac
done
for verb in up down restart setup apply egress-sync tor-recover tor-history tor-newnym backup restore upgrade reset-dashboard config-reset factory-reset firstboot-install uninstall os-update rotate-secrets; do
    printf 'pid=42 verb=%s since=2026-10-31T00:00:00Z\n' "$verb" >"$SCRATCH/target/.pithead.lock"
    out=$(cd "$SCRATCH/target" && PATH="$SCRATCH/bin:$PATH" bash -c "$(tor_recovery_lock_snapshot_snippet)")
    check grep -q "verb=$verb " <<<"$out"
done
out=$(cd "$SCRATCH/target" && PATH="$SCRATCH/bin:$PATH" LOCKS_RC=1 bash -c "$(tor_recovery_lock_snapshot_snippet)")
check grep -q '^kernel-lock: unavailable$' <<<"$out"
printf '%s\n' '{"locks": []}' >"$LOCKS_JSON"
out=$(cd "$SCRATCH/target" && PATH="$SCRATCH/bin:$PATH" bash -c "$(tor_recovery_lock_snapshot_snippet)")
check grep -q '^kernel-lock: none-observed$' <<<"$out"
jq -n --arg path "$SCRATCH/target/.pithead.lock" '{locks: [range(1;33) |
    {pid: ., type: "FLOCK", mode: "WRITE", path: $path}
]}' >"$LOCKS_JSON"
out=$(cd "$SCRATCH/target" && PATH="$SCRATCH/bin:$PATH" bash -c "$(tor_recovery_lock_snapshot_snippet)")
check test "$(grep -c '^kernel-lock: pid=' <<<"$out")" -eq 16
check grep -q '^kernel-lock: pid=16 mode=WRITE$' <<<"$out"
check test "$(grep -c '^kernel-lock: pid=17 ' <<<"$out")" -eq 0
printf 'snapshot fixture: %s passed, %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0

echo "== live Tor diagnostics rows read the snapshot and the stalled control port =="
for fixture in healthy leak slow; do
    (
        OUT_DIR="$SCRATCH/diag-$fixture"
        mkdir -p "$OUT_DIR"
        IT_FAIL=0 IT_PASS=0
        echo 100 >"$OUT_DIR/clock"
        tor_recovery_probe_now_s() { cat "$OUT_DIR/clock"; }
        rx() {
            case "$1" in
            *tor_diagnostics_snapshot*)
                if [ "$fixture" = leak ]; then
                    echo '{"control":"ok","version":"0.4.9.17","bootstrap":{"progress":100},"consensus":{"age_sec":60},"guards":{"up":1},"circuits":[{"state":"BUILT","purpose":"GENERAL","count":1,"path":"$ABCDEF0123456789ABCDEF0123456789ABCDEF01"}]}'
                else
                    echo '{"control":"ok","version":"0.4.9.17","bootstrap":{"progress":100},"consensus":{"age_sec":60},"guards":{"up":1},"circuits":[{"state":"BUILT","purpose":"GENERAL","count":1}]}'
                fi
                ;;
            *TOR_CONTROL_PORT=19051*)
                [ "$fixture" != slow ] || echo 130 >"$OUT_DIR/clock"
                printf 'control=unreachable\nconsensus_source=file\nconsensus_file_mtime=1\n'
                ;;
            *) return 1 ;;
            esac
        }
        tor_diagnostics_live_probe >/dev/null
        case "$fixture" in
        healthy)
            check test "$IT_PASS" -eq 3
            check test "$IT_FAIL" -eq 0
            ;;
        leak)
            check test "$IT_PASS" -eq 2
            check test "$IT_FAIL" -eq 1
            ;;
        slow)
            check test "$IT_PASS" -eq 2
            check test "$IT_FAIL" -eq 1
            ;;
        esac
        test "$FAIL" -eq 0
    )
done
