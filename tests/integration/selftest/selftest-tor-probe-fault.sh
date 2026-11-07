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
        env_on_box() { echo true; }
        cleared=0
        fault_rules_clear_all() { cleared=$((cleared + 1)); }
        wait_for() {
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
        printf 'binding fixture (%s): %s passed, %s failed\n' "$flag" "$PASS" "$FAIL"
        test "$FAIL" -eq 0
    )
done

echo "== Lifecycle recovery proof rejects false success and unexpected-abort advice =="
for fixture in clears refusal abort success wrong-guard busy error deadline sampler-timeout; do
    (
        IT_FAIL=0 IT_PASS=0
        OUT_DIR="$SCRATCH/$fixture"
        mkdir -p "$OUT_DIR"
        clock=0
        now_s() { echo 9999999999; }
        tor_recovery_probe_now_s() { echo "$clock"; }
        sleep() { clock=$((clock + $1)); }
        rx() {
            if [[ "$1" == *lslocks* ]]; then
                printf '%s\n' "$1" >"$OUT_DIR/sampler-command"
                [ "$fixture" != sampler-timeout ] || return 124
                printf '%s\n' 'lock-record: pid=42 verb=apply since=2026-10-31T00:00:00Z' 'kernel-lock: pid=42 mode=WRITE' 'untrusted diagnostic payload'
                return 0
            fi
            [ "$1" != 'docker exec tor /usr/local/bin/tor-recovery-diagnose.sh' ]
        }
        pithead() {
            printf '%s|%s\n' "$((60 - clock))" "${IT_PITHEAD:-./pithead}" >>"$OUT_DIR/commands"
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
        if [ "$fixture" = refusal ] || [ "$fixture" = clears ] || [ "$fixture" = sampler-timeout ]; then
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
            check test "$clock" -eq 60
            check test "$(wc -l <"$OUT_DIR/calls")" -eq 30
            check grep -q 'admission: elapsed_s=60 rc=75' "$OUT_DIR/tor-recovery-admission.log"
            ;;
        sampler-timeout)
            check test "$(wc -l <"$OUT_DIR/calls")" -eq 3
            check grep -q '^kernel-lock: unavailable$' "$OUT_DIR/tor-recovery-admission.log"
            ;;
        deadline)
            check test "$(wc -l <"$OUT_DIR/calls")" -eq 1
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
