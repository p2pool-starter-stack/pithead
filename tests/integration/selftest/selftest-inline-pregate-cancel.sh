#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$HERE/.." <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1]).resolve()
harness = (root / "e2e.sh").read_text().split("run_harness() {", 1)[1].split("\n}\n", 1)[0]
harness = "run_harness() {" + harness + "\n}\n"


def eventually(predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.02)
    raise AssertionError("fixture did not reach expected state")


def members(group):
    rows = subprocess.check_output(["ps", "-axo", "pgid=,stat="], text=True)
    return [row for row in rows.splitlines()
            if row.split()[0] == str(group) and not row.split()[1].startswith("Z")]


with tempfile.TemporaryDirectory() as scratch:
    work = Path(scratch)
    child = work / "child.py"
    child.write_text("""
import os, signal, sys, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(sys.argv[1]).write_text(str(os.getpgrp()))
while True:
    time.sleep(.02)
    if Path(sys.argv[2]).exists():
        Path(sys.argv[3]).touch()
""")
    for delivery in ("parent", "tree"):
        run = work / delivery
        run.mkdir()
        env = dict(os.environ, LIB=str(root / "lib" / "parent-lock.sh"),
                   DETACHED=str(root / "lib" / "detached-harness.sh"),
                   RUN=str(run), CHILD=str(child))
        script = r'''
source "$LIB"
source "$DETACHED"
warn() { echo "$*" >&2; }
restore_all() { touch "$RUN/restore"; sleep .2; }
rig_lock_remote_release() { touch "$RUN/released"; }
redact_remote_output() { cat; }
RIG_LOCK_PARENT_ACTOR=fixture
MODE=targeted BORROW_MINER=0 WORKERS=1 BENCH_HOST=fixture E2E_DIR=fixture
REMOTE_NODE_ARGS=() HARNESS_PHASE_ARGS="" HARNESS_SCENARIO_ARGS=""
log() { :; }
harness_install_runner() { :; }
on_bench() {
    case "$1" in
        *--readiness*)
            python3 "$CHILD" "$RUN/group" "$RUN/restore" "$RUN/late"
            ;;
        *--check*) touch "$RUN/check" ;;
    esac
}
trap e2e_exit EXIT
''' + harness + r'''
run_harness
touch "$RUN/continued"
'''
        unrelated = subprocess.Popen(["sleep", "30"], start_new_session=True)
        proc = subprocess.Popen(["bash", "-c", script], env=env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                start_new_session=True)
        group = None
        try:
            eventually(lambda: (run / "group").exists() and (run / "group").read_text().isdigit())
            group = int((run / "group").read_text())
            if delivery == "tree":
                os.killpg(group, signal.SIGTERM)
            proc.send_signal(signal.SIGTERM)
            _, err = proc.communicate(timeout=15)
            assert proc.returncode != 0, "cancellation became success"
            assert (run / "restore").exists(), str(err)
            assert (run / "released").exists(), "lease child was not released"
            assert not members(group), "pregate descendant survived restoration"
            assert not (run / "late").exists(), "assertion ran against restored baseline"
            assert not (run / "check").exists(), "check ran after cancellation"
            assert not (run / "continued").exists(), "candidate run continued"
            assert unrelated.poll() is None, "unrelated process was signalled"
            print(f"PASS: {delivery} TERM drains stubborn pregate before restore")
        finally:
            if group and members(group):
                os.killpg(group, signal.SIGKILL)
            if proc.poll() is None:
                proc.kill()
            proc.communicate(timeout=5)
            unrelated.terminate()
            unrelated.wait(timeout=5)

    for status in (0, 7):
        run = work / str(status)
        run.mkdir()
        env = dict(os.environ, LIB=str(root / "lib" / "parent-lock.sh"),
                   RUN=str(run), STATUS=str(status))
        result = subprocess.run(["bash", "-c", r'''
source "$LIB"
RIG_LOCK_PARENT_ACTOR=fixture
harness_pregate() { echo output; echo error >&2; return "$STATUS"; }
redact_remote_output() { sleep .2; cat; }
restore_all() { touch "$RUN/restore"; return 0; }
rig_lock_remote_release() { touch "$RUN/released"; }
trap e2e_exit EXIT
run_inline_pregate 1 ""
exit $?
'''], env=env, timeout=10, capture_output=True)
        assert result.returncode == status, result.stderr.decode()
        assert (run / "restore").exists()
        assert (run / "released").exists()
        print(f"PASS: pregate exit {status} is preserved after drain and restore")

    run = work / "unverified"
    run.mkdir()
    env = dict(os.environ, LIB=str(root / "lib" / "parent-lock.sh"), RUN=str(run))
    result = subprocess.run(["bash", "-c", r'''
source "$LIB"
RIG_LOCK_PARENT_ACTOR=fixture
harness_pregate() { return 0; }
redact_remote_output() { cat; }
ps() { return 1; }
warn() { echo "$*" >&2; }
restore_all() { touch "$RUN/restore"; }
rig_lock_remote_release() { touch "$RUN/released"; }
trap e2e_exit EXIT
run_inline_pregate 1 ""
exit $?
'''], env=env, timeout=10, capture_output=True)
    assert result.returncode == 1
    assert not (run / "restore").exists(), "unverified drain allowed restoration"
    assert not (run / "released").exists(), "unverified drain released its reservation"
    print("PASS: process inspection failure refuses restoration")
PY
