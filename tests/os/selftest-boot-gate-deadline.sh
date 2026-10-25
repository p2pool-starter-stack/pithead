#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/boot-gate-deadline.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
# shellcheck source=os/overlay/pithead-boot
source "${BOOT_SOURCE:-$ROOT/os/overlay/pithead-boot}"
declare -F gate_run >/dev/null || fail 'health probes have no shared deadline wrapper'
BOOT_DOCTOR_JSON="$scratch/doctor.json"
BOOT_STATUS_LOG="$scratch/status.log"
BOOT_GATE_PROBE_SECONDS=1
started=$SECONDS
result=0
gate_run doctor bash -c 'trap "" TERM; sleep 30' || result=$?
[ "$result" -ne 0 ] || fail 'a stuck probe succeeded'
[ "$((SECONDS - started))" -le 5 ] || fail 'a stuck probe escaped its kill bound'
[ "$gate_timeout_reason" = doctor ] || fail 'the timeout cause was lost'
BOOT_GATE_PROBE_SECONDS=30
gate_deadline=$SECONDS
gate_run doctor touch "$scratch/expired" && fail 'an expired gate ran another probe'
[ ! -e "$scratch/expired" ] || fail 'an expired gate executed a command'
unset gate_deadline
mkdir "$scratch/stack"
cat >"$scratch/stack/pithead" <<'STUB'
#!/usr/bin/env bash
case "$1" in
doctor) printf '{"checks":[]}\n' ;;
status) printf '  ⚠ dashboard UNHEALTHY\n' ;;
esac
STUB
chmod +x "$scratch/stack/pithead"
(
    cd "$scratch/stack"
    gate_ready 200 10 && fail 'an unhealthy status with exit zero committed'
    [ "$(boot_status_blocking)" = 'container dashboard: UNHEALTHY' ] || fail 'the blocking container was lost'
)
(
    cd "$scratch/stack"
    timeout() {
        printf '{"checks":[{"status":"fail","message":"The dashboard certificate does not cover: test"}]}\n'
        return 124
    }
    gate_doctor_ran=0
    gate_ready 200 10 && fail 'a partial timed-out doctor committed'
    [ "$gate_doctor_ran" -eq 0 ] || fail 'a timed-out doctor became a certificate advisory'
)
awk '/^gate_wait_started=/{capture=1} capture{print}' "$ROOT/os/overlay/pithead-boot" >"$scratch/loop.sh"
[ -s "$scratch/loop.sh" ] || fail 'the production gate loop was not selected'
for scenario in unhealthy slow-dashboard slow-doctor slow-status slow-render late-success commit-failed commit-timeout healthy; do
    result=0
    (
        cd "$scratch/stack"
        SECONDS=0
        BOOT_GATE_WAIT_SECONDS=60
        gate_target=https://localhost/.pithead-boot-health
        gate_resolve_args=()
        gate_advisory=''
        OS_INFLIGHT="$scratch/no-update"
        hold_chain=0
        gate_probe_header() { :; }
        curl() {
            printf '200 10'
            [ "$scenario" != slow-dashboard ] || return 28
        }
        sleep() { SECONDS=$((SECONDS + $1)); }
        gate_blocked_only_by_cert() { [ "$scenario" = slow-render ]; }
        gate_cert_advisory_ready() { return 1; }
        boot_gate_passed() { touch "$scratch/committed-$scenario"; }
        rauc() { touch "$scratch/committed-$scenario"; }
        fail_boot() {
            [ "$SECONDS" -le 60 ] || fail "deadline exceeded: $scenario ($SECONDS seconds)"
            printf '%s\n' "${gate_timeout_reason:-unhealthy}" >"$scratch/reason-$scenario"
            exit 1
        }
        timeout() {
            [ "$1" != 1800 ] || return 0
            [ "$1" = --kill-after=2 ] || fail 'probe has no forced-kill grace'
            local budget=$2 operation=$4 duration=0
            [ "$3" != curl ] || {
                curl
                return
            }
            if [ "$3" = rauc ]; then
                case "$scenario" in
                commit-failed) return 1 ;;
                commit-timeout)
                    SECONDS=$((SECONDS + budget + 2))
                    return 124
                    ;;
                esac
                rauc status mark-good
                return
            fi
            shift 2
            case "$scenario:$operation" in
            slow-doctor:doctor | slow-status:status | slow-render:render) duration=120 ;;
            unhealthy:doctor) duration=20 ;;
            late-success:doctor) SECONDS=60 ;;
            esac
            if [ "$duration" -gt "$budget" ]; then
                SECONDS=$((SECONDS + budget + 2))
                printf '{"checks":[{"status":"fail","message":"The dashboard certificate does not cover: test"}]}\n'
                return 124
            fi
            SECONDS=$((SECONDS + duration))
            case "$operation" in
            doctor)
                printf '{"checks":[]}\n'
                [ "$scenario" != slow-render ]
                ;;
            status)
                case "$scenario" in
                unhealthy | slow-doctor | slow-render) printf '  ⚠ dashboard UNHEALTHY\n' ;;
                *) printf 'healthy\n' ;;
                esac
                ;;
            local-miner) return 0 ;;
            *) return 0 ;;
            esac
        }
        # shellcheck disable=SC1090
        source "$scratch/loop.sh"
    ) >"$scratch/$scenario.log" 2>&1 || result=$?
    if [ "$scenario" = healthy ]; then
        [ "$result" -eq 0 ] && [ -f "$scratch/committed-$scenario" ] || fail 'healthy slot did not commit'
    else
        [ "$result" -eq 1 ] && [ -s "$scratch/reason-$scenario" ] || {
            cat "$scratch/$scenario.log" >&2
            fail "failure did not reach bounded recovery: $scenario"
        }
        [ ! -f "$scratch/committed-$scenario" ] || fail "failed slot committed: $scenario"
    fi
done
(
    gate_target=https://localhost/.pithead-boot-health
    gate_resolve_args=()
    gate_probe_header() { :; }
    timeout() {
        printf '200 10'
        return 124
    }
    gate_timeout_reason=''
    gate_probe_dashboard
    [ "$gate_timeout_reason" = dashboard ] || fail 'dashboard timeout cause was lost in a subshell'
    [ "$code" = 000 ] && [ "$size" = 0 ] || fail 'partial dashboard timeout output remained healthy'
    if gate_ready "$code" "$size"; then fail 'a partial timed-out dashboard response committed'; fi
)
(
    cd "$scratch/stack"
    gate_remint_state=restart-pending
    PITHEAD_CADDY_RESTART_CMD=false
    gate_ready 200 10 && fail 'a failed Caddy restart permitted commit'
    [ "$gate_remint_state" = restart-pending ] || fail 'a failed Caddy restart lost its pending state'
    PITHEAD_CADDY_RESTART_CMD=true
    cat >pithead <<'HEALTHY'
#!/usr/bin/env bash
case "$1" in
doctor) printf '{"checks":[]}\n' ;;
status) printf 'healthy\n' ;;
esac
HEALTHY
    chmod +x pithead
    if gate_ready 000 0; then fail 'an unavailable dashboard committed after restart'; fi
    [ "$gate_remint_state" = reminted ] || fail 'an unavailable dashboard prevented Caddy restart recovery'
    gate_ready 200 10 || fail 'a recovered Caddy restart still prevented commit'
    [ "$gate_remint_state" = reminted ] || fail 'a successful restart did not clear its pending state'
)
printf '{"to":"fault"}\n' >"$scratch/inflight.json"
printf '{"checks":[]}\n' >"$BOOT_DOCTOR_JSON"
printf '  ⚠ dashboard UNHEALTHY\n' >"$BOOT_STATUS_LOG"
for failures in 1 2; do
    rm -f "$scratch/rebooted"
    result=0
    (
        BOOT_FAIL_COUNT="$scratch/failure-count"
        OS_INFLIGHT="$scratch/inflight.json"
        gate_deadline=$SECONDS
        gate_timeout_reason=doctor
        gate_remint_state=restart-pending
        PITHEAD_REBOOT_CMD="touch $scratch/rebooted"
        boot_status() { touch "$scratch/extra-status"; }
        fail_boot 'the stack never became healthy (serving + doctor + status)'
    ) >"$scratch/recovery-$failures.log" 2>&1 || result=$?
    [ "$result" -eq 1 ] || fail 'failed boot returned success'
    [ "$(cat "$scratch/failure-count")" = "$failures" ] || fail 'failure budget changed'
    [ ! -e "$scratch/extra-status" ] || fail 'recovery ran another probe after expiry'
    if [ "$failures" -eq 1 ]; then
        [ -e "$scratch/rebooted" ] || fail 'first failure did not reboot'
    else
        [ ! -e "$scratch/rebooted" ] || fail 'fallback failure rebooted again'
    fi
done
jq -e '.blocking | index("Health probe exceeded its time budget: doctor") != null and index("container dashboard: UNHEALTHY") != null and index("container caddy: certificate restart failed") != null' \
    "$scratch/inflight.json" >/dev/null || fail 'fallback lost its retained cause'
sed -n "/| awk '/,/^    '; then/p" "$HERE/phases/update-healthgate-leg.sh" | sed '1d;$d' >"$scratch/timing.awk"
[ -s "$scratch/timing.awk" ] || fail 'the KVM timing verdict was not selected'
for finish in 970 975 976 9 missing; do
    printf '[   10.000] host pithead-boot: health gate started; deadline 960 seconds\n' >"$scratch/journal"
    if [ "$finish" != missing ]; then
        printf '[ %s.000] host pithead-boot: the stack never became healthy (serving + doctor + status)\n' "$finish" >>"$scratch/journal"
    fi
    result=0
    awk -f "$scratch/timing.awk" "$scratch/journal" || result=$?
    case "$finish:$result" in
    970:0 | 975:0 | 976:1 | 9:1 | missing:1) ;;
    *) fail "KVM timing verdict accepted or rejected the wrong journal: $finish" ;;
    esac
done
printf 'selftest-boot-gate-deadline: probe, commit, restart, recovery and journal controls passed (nine production-loop scenarios)\n'
