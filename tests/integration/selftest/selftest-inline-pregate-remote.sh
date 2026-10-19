#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$HERE/../lib/inline-pregate-remote.sh" <<'PY'
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time

if sys.platform != "linux":
    print("SKIP: remote pregate identity checks require Linux /proc; exercised by Linux CI")
    sys.exit(0)
helper = str(Path(sys.argv[1]).resolve())


def eventually(predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.02)
    raise AssertionError("remote fixture did not reach expected state")


def alive(group):
    rows = subprocess.check_output(["ps", "-axo", "pgid=,stat="], text=True)
    return any(row.split()[0] == str(group) and not row.split()[1].startswith("Z")
               for row in rows.splitlines())


def drain(state):
    return subprocess.run(["bash", helper, "drain", str(state)],
                          capture_output=True, timeout=15)


with tempfile.TemporaryDirectory() as scratch:
    work = Path(scratch)
    child = work / "child.py"
    child.write_text("""
import signal, sys, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(sys.argv[1]).touch()
while True:
    time.sleep(.02)
    if Path(sys.argv[2]).exists():
        Path(sys.argv[3]).touch()
""")
    for leader_killed in (False, True):
        state = work / f"state-{leader_killed}"
        ready, restored, late = [work / f"{n}-{leader_killed}"
                                 for n in ("ready", "restored", "late")]
        state.write_text("intent\n")
        command = shlex.join(["python3", str(child), str(ready), str(restored), str(late)])
        proc = subprocess.Popen(["bash", helper, "run", str(state), command],
                                start_new_session=True, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        try:
            eventually(ready.exists)
            if leader_killed:
                proc.kill()
                proc.wait(timeout=5)
            result = drain(state)
            assert result.returncode == 0, result.stderr.decode()
            assert state.read_text() == "stopped\n"
            assert not alive(proc.pid), "remote descendant survived drain"
            restored.touch()
            time.sleep(.1)
            assert not late.exists(), "remote assertion ran after restoration"
            print(f"PASS: remote drain with leader_killed={leader_killed}")
        finally:
            if alive(proc.pid):
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5)

    state = work / "delayed"
    state.write_text("intent\n")
    assert drain(state).returncode == 0
    marker = work / "launched"
    result = subprocess.run(["bash", helper, "run", str(state),
                             "touch " + shlex.quote(str(marker))],
                            start_new_session=True, capture_output=True, timeout=5)
    assert result.returncode == 143
    assert not marker.exists(), "delayed launch ignored the stop record"
    print("PASS: drain prevents a delayed remote launch")

    state = work / "normal"
    state.write_text("intent\n")
    result = subprocess.run(["setsid", "--wait", "bash", helper, "run", str(state), "echo output; exit 7"],
                            start_new_session=True, capture_output=True, timeout=5)
    assert result.returncode == 7 and result.stdout == b"output\n"
    assert drain(state).returncode == 0
    print("PASS: normal remote exit and output preserved")

    victim = subprocess.Popen(["sleep", "30"], start_new_session=True)
    try:
        state = work / "wrong-identity"
        state.write_text(f"running {victim.pid} 0\n")
        assert drain(state).returncode != 0
        assert victim.poll() is None, "wrong process identity was signalled"
        state.write_text("invalid\n")
        assert drain(state).returncode != 0
        print("PASS: invalid or changed identity refuses drain")
    finally:
        victim.terminate()
        victim.wait(timeout=5)
PY
