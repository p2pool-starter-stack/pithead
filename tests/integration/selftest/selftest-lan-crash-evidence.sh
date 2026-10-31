#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=${LAN_CRASH_SOURCE_ROOT:-$HERE/..}
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/stack/data/lan-guard"
export CAPTURE_CALLS="$fixture/calls"
cat >"$fixture/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "docker $*" >>"$CAPTURE_CALLS"
echo 'fixture-private-credential' >&2
printf 'node=false exit=137 oom=false starts=0 started=%s finished=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s=%s\n' secret fixture-private-credential
DOCKER
cat >"$fixture/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "systemctl $*" >>"$CAPTURE_CALLS"
printf '%s\n' 'ActiveState=inactive' 'SubState=dead' 'Result=exit-code' 'ExecMainStatus=7' 'ExecMainStartTimestampMonotonic=1234' 'ExecMainExitTimestampMonotonic=2345' 'LastTriggerUSecMonotonic=1w 2d' 'NextElapseUSecMonotonic=' 'Environment=fixture-private-credential'
SYSTEMCTL
chmod +x "$fixture/bin/docker" "$fixture/bin/systemctl"
export PATH="$fixture/bin:$PATH"
IT_MODE=local IT_REMOTE_DIR="$fixture/stack"
IT_SSH_OPTS=()
IT_SSH_DEST=unused
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-lan-guard.sh
source "$ROOT/lib/run-lan-guard.sh"
LAN_CRASH_EVIDENCE="$fixture/observations.log"

echo "== crash capture retains timestamped state and execution properties without raw values =="
_lan_crash_capture monerod after-exit 137 "$(($(date +%s) + 10))"
grep -Eq '^sample_utc=[0-9TZ:-]+ stage=after-exit observed=137$' "$LAN_CRASH_EVIDENCE"
grep -Eq '^captured_utc=[0-9TZ:-]+$' "$LAN_CRASH_EVIDENCE"
grep -q '^node=false exit=137 oom=false starts=0 started=.* finished=' "$LAN_CRASH_EVIDENCE"
for expected in 'unit=pithead-lan.timer' 'unit=pithead-lan-check.service' 'Result=exit-code' 'ExecMainStatus=7' 'ExecMainStartTimestampMonotonic=1234' 'ExecMainExitTimestampMonotonic=2345' 'marker=absent'; do
    grep -Fxq "$expected" "$LAN_CRASH_EVIDENCE"
done
! grep -q 'fixture-private-credential' "$LAN_CRASH_EVIDENCE"
! grep -Eq '^(LastTrigger|NextElapse)' "$LAN_CRASH_EVIDENCE"
grep -Fxq capture=filtered "$LAN_CRASH_EVIDENCE"
[ "$(wc -l <"$CAPTURE_CALLS")" -eq 3 ]

echo "== failed oversized and hostile capture inputs remain unavailable =="
(
    rx() {
        echo fixture-private-credential
        return 1
    }
    _lan_crash_capture monerod recovery fixture-private-credential "$(($(date +%s) + 10))"
)
(
    rx() { printf '%09000d\n' 0; }
    _lan_crash_capture monerod recovery false "$(($(date +%s) + 10))"
)
[ "$(grep -c '^capture=unavailable$' "$LAN_CRASH_EVIDENCE")" -eq 2 ]
grep -q 'stage=recovery observed=unavailable' "$LAN_CRASH_EVIDENCE"
! grep -q 'fixture-private-credential' "$LAN_CRASH_EVIDENCE"

echo "== diagnostic transport has a hard bound and respects an expired recovery window =="
start=$(date +%s)
(
    rx() { sleep 60; }
    _lan_crash_capture monerod recovery false "$((start + 10))"
)
[ "$(($(date +%s) - start))" -le 8 ]
[ "$(grep -c '^capture=unavailable$' "$LAN_CRASH_EVIDENCE")" -eq 3 ]
before=$(wc -l <"$LAN_CRASH_EVIDENCE")
_lan_crash_capture monerod recovery false "$(date +%s)"
[ "$(wc -l <"$LAN_CRASH_EVIDENCE")" -eq "$before" ]

echo "== real crash harness preserves deadline nonzero rule and missing-rule controls =="
for recovery in success timeout storage-failure write-failure multiple-nodes invalid-target; do
    echo "== crash harness $recovery =="
    (
        OUT_DIR="$fixture/$recovery"
        mkdir -p "$OUT_DIR"
        clock="$OUT_DIR/clock"
        echo 1000 >"$clock"
        trace="$OUT_DIR/trace"
        : >"$trace"
        negative=0 restored=0 failures=0
        if [ "$recovery" = storage-failure ]; then mktemp() { return 1; }; fi
        date() { if [ "$1" = +%s ]; then cat "$clock"; else command date "$@"; fi; }
        sleep() { echo "$(($(cat "$clock") + $1))" >"$clock"; }
        _lan_crash_capture() {
            printf '%s|%s|%s|%s\n' "$2" "$3" "$4" "$(date +%s)" >>"$trace"
            printf 'target|%s|%s|%s\n' "$1" "$2" "$LAN_CRASH_EVIDENCE" >>"$trace"
            if [ "$recovery" = write-failure ]; then
                (
                    source "$ROOT/lib/lan-crash-evidence.sh"
                    LAN_CRASH_EVIDENCE="$OUT_DIR"
                    _lan_crash_capture "$@"
                )
            fi
        }
        _lan_exit_code() { echo 137; }
        _lan_timer_pause() {
            negative=1
            echo timer-pause >>"$trace"
        }
        _lan_flush_rules() { echo rule-flush >>"$trace"; }
        rx() {
            case "$1" in
            *container_engine*) echo docker ;;
            *lan_guard_container*)
                if [ "$recovery" = invalid-target ]; then
                    echo invalid-node
                elif [[ "$1" = *18142* ]]; then
                    echo tari
                else
                    echo monerod
                fi
                ;;
            *'docker kill --signal SEGV'*) echo segv >>"$trace" ;;
            *'docker kill --signal KILL'*) echo kill >>"$trace" ;;
            *'docker inspect'*)
                if [ "$restored" = 1 ] || { [ "$negative" = 0 ] && [ "$recovery" != timeout ] && [ "$(date +%s)" -ge 1010 ]; }; then echo true; else echo false; fi
                ;;
            *lan_guard_enforced*) echo live ;;
            *'systemctl start'*) echo timer-start >>"$trace" ;;
            *'test -e data'*) ;;
            './pithead up')
                restored=1
                echo up >>"$trace"
                ;;
            *)
                echo "unexpected rx" >&2
                exit 1
                ;;
            esac
        }
        assert_eq() {
            if [ "$2" != "$3" ]; then
                [ "$recovery" = timeout ] && [[ "$1" = *'running again within the timer interval'* ]] || exit 1
                failures=$((failures + 1))
            fi
            printf 'assert:%s\n' "$1" >>"$trace"
        }
        assert_ne() {
            [ "$2" != "$3" ]
            printf 'assert:%s\n' "$1" >>"$trace"
        }
        assert_rc() { [ "$2" = "$3" ]; }
        it_fail() {
            if [ "$recovery" = invalid-target ]; then
                [ "$1" = 'LAN crash target is a known node' ] || exit 1
                echo invalid-target >>"$trace"
                return 0
            fi
            if [ "$recovery" = write-failure ] && [ "$1" = 'LAN crash evidence retained' ]; then
                echo retention-fail >>"$trace"
                return 0
            fi
            [ "$recovery" = storage-failure ] && [ "$1" = 'LAN crash diagnostic storage available' ] || exit 1
            failures=$((failures + 1))
        }
        ports=(18081)
        if [ "$recovery" = multiple-nodes ]; then ports+=(18142); fi
        assert_lan_guard_crash_restart "${ports[@]}"
        if [ "$recovery" = invalid-target ]; then
            grep -Fxq invalid-target "$trace"
            ! grep -Eq '^(target\||segv|kill)' "$trace"
            exit 0
        fi
        grep -q '^before-crash|unknown|' "$trace"
        grep -q '^after-exit|137|1180|1000$' "$trace"
        grep -q '^recovery|false|1180|' "$trace"
        grep -q '^before-negative|unknown|' "$trace"
        grep -q 'assert:the rule is still live' "$trace"
        grep -q 'assert:monerod stays down while the rule is missing' "$trace"
        grep -q 'assert:monerod runs again after up' "$trace"
        grep -Fxq 'assert:monerod crashed with a non-zero exit code (#3290)' "$trace"
        [ "$(grep -Fc 'assert:...and it was not a clean exit (#3290)' "$trace")" -eq "${#ports[@]}" ]
        [ "$(grep -c '^segv$' "$trace")" -eq "${#ports[@]}" ]
        [ "$(grep -c '^kill$' "$trace")" -eq 1 ]
        if [ "$recovery" = multiple-nodes ]; then
            grep -Fxq 'assert:tari crashed with a non-zero exit code (#3290)' "$trace"
            monerod_evidence=$(grep '^target|monerod|before-crash|' "$trace" | cut -d '|' -f 4)
            tari_evidence=$(grep '^target|tari|before-crash|' "$trace" | cut -d '|' -f 4)
            [ "$monerod_evidence" != "$tari_evidence" ]
            grep -Fxq "target|monerod|before-negative|$monerod_evidence" "$trace"
            ! grep -q '^target|tari|before-negative|' "$trace"
        fi
        if [ "$recovery" = timeout ]; then
            [ "$failures" = 1 ]
            grep -q '^before-negative|unknown|1184|1180$' "$trace"
        else
            if [ "$recovery" = storage-failure ]; then [ "$failures" = 1 ]; else [ "$failures" = 0 ]; fi
            grep -q '^recovery|true|1180|1010$' "$trace"
            if [ "$recovery" = write-failure ]; then grep -q '^retention-fail$' "$trace"; fi
        fi
    )
done
echo 'selftest-lan-crash-evidence: PASS'
