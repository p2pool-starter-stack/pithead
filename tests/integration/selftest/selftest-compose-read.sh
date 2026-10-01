#!/usr/bin/env bash
# Compose diagnostics retain the assertion's original read, before later probes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-matrix.sh"
source "$HERE/../lib/run-state.sh"
TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT
mkdir -p "$TD/bin" "$TD/out"
export COMPOSE_TEST_TRACE="$TD/trace" COMPOSE_TEST_MODE=success
export PATH="$TD/bin:$PATH"
export IT_MODE=local IT_REMOTE_DIR="$TD" OUT_DIR="$TD/out"
cat >"$TD/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$COMPOSE_TEST_TRACE"
case "$*" in
'compose ps --services --status running')
    printf 'tor\ncaddy\n'
    case "$COMPOSE_TEST_MODE" in
    success) printf 'docker-control\n' ;;
    read-error)
        echo 'TOKEN=read-secret' >&2
        python3 -c 'import sys; print("__compose_exit=" + "9" * 5000, file=sys.stderr)'
        echo '__compose_exit=0' >&2
        exit 42 ;;
    esac ;;
'compose ps -a')
    case "$COMPOSE_TEST_MODE" in
    capture-error) echo 'PASSWORD=capture-secret' >&2; exit 17 ;;
    large)
        python3 -c 'print("x" * 70000); print("TOKEN=large-secret"); print("safe tail")'
        python3 -c 'import sys; print("y" * 70000, file=sys.stderr)' ;;
    *) echo 'docker-control exited'; echo 'TOKEN=ps-secret' >&2 ;;
    esac ;;
*) echo later >>"$COMPOSE_TEST_TRACE"; echo 0 ;;
esac
DOCKER
chmod +x "$TD/bin/docker"

# Stop after the first later probe; the real membership loop and collector run unchanged.
run_case() (
    jq_get() { case "$2" in .monero.mode | .tari.mode) echo local ;; *) echo false ;; esac }
    clearnet_flag_effective() { echo false; }
    expected_services() { printf 'caddy\ndocker-control\nsecond-missing\n'; }
    wait_for() { :; }
    rx() {
        if [ "$1" = "docker exec tor grep -c -F 'HiddenServiceDir /var/lib/tor/monero/' /tmp/torrc 2>/dev/null" ]; then
            echo later >>"$COMPOSE_TEST_TRACE"
            exit 0
        fi
        (cd "$IT_REMOTE_DIR" && bash -c "$1")
    }
    assert_num_ge() { exit 0; }
    assert_running_state "$1" '{}'
)

check_json() {
    local name="$1" file="$2" expression="$3"
    jq -e "$expression" "$file" >/dev/null
    assert_rc "$name" "$?" 0
}

snapshot="$(mktemp -d "$TD/snapshot.XXXXXX")"
running="$(running_services "$snapshot" healthy)"
assert_eq "successful original read preserves sorted membership" "$running" $'caddy\ndocker-control\ntor'
check_json "success retains Compose's own zero status" "$OUT_DIR/healthy/running-services.json" '.compose_exit == 0 and .transport_exit == 0 and .capture_error == null'
assert_eq "successful snapshot stdout is retained unsorted" "$(cat "$OUT_DIR/healthy/running-services.stdout")" $'tor\ncaddy\ndocker-control'
assert_eq "successful reads do not trigger ps -a" "$(grep -c 'compose ps -a' "$COMPOSE_TEST_TRACE")" 0

for mode in missing read-error capture-error large; do
    export COMPOSE_TEST_MODE="$mode"
    : >"$COMPOSE_TEST_TRACE"
    output="$(run_case "$mode")"
    assert_contains "original failed row survives $mode" "$output" 'container up: docker-control'
    assert_contains "original failure detail survives $mode" "$output" 'not in running services'
    assert_contains "later missing row survives $mode" "$output" 'container up: second-missing'
    assert_eq "one additional capture per snapshot for $mode" "$(grep -c '^compose ps -a$' "$COMPOSE_TEST_TRACE")" 1
    assert_eq "capture runs before later probe for $mode" "$(cat "$COMPOSE_TEST_TRACE")" $'compose ps --services --status running\ncompose ps -a\nlater'
    assert_contains "scenario is identified for $mode" "$(cat "$OUT_DIR/$mode/service-read.txt")" "scenario=$mode"
    assert_contains "failed service is identified for $mode" "$(cat "$OUT_DIR/$mode/service-read.txt")" 'failed_service=docker-control'
    check_json "capture timestamp and time bound retained for $mode" "$OUT_DIR/$mode/compose-ps-all.json" '.captured_at != null and .time_limit_seconds == 8 and .byte_limit_per_stream == 65536'
    if [ "$mode" = read-error ]; then
        check_json "read failure retains original Compose status instead of sort status" "$OUT_DIR/$mode/running-services.json" '.compose_exit == 42 and .transport_exit == 42 and .capture_error == "Compose read failed"'
        assert_contains "read failure retains redacted stderr" "$(cat "$OUT_DIR/$mode/running-services.stderr")" 'TOKEN=<redacted>'
    fi
    if [ "$mode" = capture-error ]; then
        check_json "failed ps -a retains its exit status" "$OUT_DIR/$mode/compose-ps-all.json" '.compose_exit == 17 and .transport_exit == 17'
        assert_contains "failed capture still retains safe stderr" "$(cat "$OUT_DIR/$mode/compose-ps-all.stderr")" 'PASSWORD=<redacted>'
    fi
    if [ "$mode" = large ]; then
        check_json "both stream truncations are explicit" "$OUT_DIR/$mode/compose-ps-all.json" '.stdout_truncated and .stderr_truncated'
        assert_contains "later safe lines survive oversized lines" "$(cat "$OUT_DIR/$mode/compose-ps-all.stdout")" 'safe tail'
        for stream in stdout stderr; do
            bytes="$(wc -c <"$OUT_DIR/$mode/compose-ps-all.$stream")"
            [ "$bytes" -le 65536 ]
            assert_rc "retained $stream has a byte bound" "$?" 0
        done
    fi
done
assert_eq "no diagnostic secret reaches results" "$(rg -l 'read-secret|ps-secret|capture-secret|large-secret' "$OUT_DIR" | wc -l)" 0

# A failed transport has no fabricated Compose status, and a hung capture is bounded.
snapshot="$(mktemp -d "$TD/snapshot.XXXXXX")"
rx() {
    echo 'TOKEN=transport-secret' >&2
    return 255
}
compose_read "$snapshot" transport true
check_json "transport error retains status and missing-status marker" "$snapshot/transport.json" '.transport_exit == 255 and .compose_exit == null and .capture_error != null'
rx() {
    echo 'safe before stall'
    sleep 30
}
compose_read "$snapshot" stalled true --seconds 0.2
check_json "time bound records capture error" "$snapshot/stalled.json" '.capture_error == "time limit exceeded" and .transport_exit != 0'
assert_contains "timeout preserves completed safe output" "$(cat "$snapshot/stalled.stdout")" 'safe before stall'
rx() {
    exec >/dev/null 2>&1
    sleep 30
}
started=$SECONDS
compose_read "$snapshot" closed-streams true --seconds 0.2
check_json "closed streams cannot bypass the transport deadline" "$snapshot/closed-streams.json" '.capture_error == "time limit exceeded" and .transport_exit != 0'
[ "$((SECONDS - started))" -lt 3 ]
assert_rc "closed-stream capture returns within its time bound" "$?" 0
python3 "$HERE/../lib/compose-read.py" --status-marker test= "$snapshot" unavailable missing-compose-test-command
check_json "command-start error still writes capture-error metadata" "$snapshot/unavailable.json" '.capture_error != null and .compose_exit == null'
python3 - "$HERE/../lib/compose-read.py" "$snapshot" <<'PYTEST'
import importlib.util
import subprocess
import sys
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("collector", sys.argv[1])
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)
stream = collector.Stream(b"test=")
stream.feed(b"test=" + b"9" * 5000 + b"\n", stderr=True)
assert stream.compose_exit is None
assert len(stream.data) == 5006
children = []
real_popen = subprocess.Popen
real_read = collector.os.read

def track(*args, **kwargs):
    child = real_popen(*args, **kwargs)
    children.append(child)
    return child

def fail_read(fd, size):
    if children:
        raise OSError("synthetic read error")
    return real_read(fd, size)

argv = [sys.argv[1], "--status-marker", "test=", sys.argv[2], "read-error", sys.executable,
        "-c", "import time; print('ready', flush=True); time.sleep(30)"]
with patch.object(sys, "argv", argv), patch.object(collector.subprocess, "Popen", track), \
        patch.object(collector.os, "read", side_effect=fail_read):
    collector.main()
assert children[0].poll() is not None
assert children[0].stdout.closed and children[0].stderr.closed
PYTEST
assert_rc "malformed markers are safe and I/O errors reap the capture child" "$?" 0
check_json "I/O error still records capture-error metadata" "$snapshot/read-error.json" '.capture_error != null and .transport_exit != null'
echo "selftest-compose-read: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
