"""The recovery proof's command plumbing: the subprocess it runs and the refusal reasons it accepts."""

import importlib.util
import json
import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "proof", HERE.parent / "tools/prove-wallet-recovery.py"
)
proof = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proof)


class RunRecoveryTest(unittest.TestCase):
    STUB = """
import json, os, signal, sys, time
from pathlib import Path
data = sys.stdin.buffer.read()
record = {"argv": sys.argv[1:], "stdin": data.decode(), "lock": os.environ.get("RIG_LOCK_FILE")}
fd = os.environ.get("RIG_LOCK_PARENT_FD", "")
if fd:
    try:
        os.fstat(int(fd))
        record["fd_open"] = True
    except OSError:
        record["fd_open"] = False
Path(os.environ["STUB_RECORD"]).write_text(json.dumps(record))
sys.stderr.write("stub stderr line\\n")
if os.environ.get("STUB_SLEEP"):
    def stopped(signum, frame):
        Path(os.environ["STUB_RECORD"] + ".term").write_text("terminated")
        sys.exit(0)
    signal.signal(signal.SIGTERM, stopped)
    time.sleep(60)
print('{"ok": 1}')
sys.exit(int(os.environ.get("STUB_EXIT", "0")))
"""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "wallet_fixture_recovery.py").write_text(self.STUB)
        self.record = self.root / "record.json"
        self.log = self.root / "recovery.log"
        self.previous = os.umask(0o077)
        patcher = patch.dict(os.environ, {"STUB_RECORD": str(self.record)})
        patcher.start()
        self.addCleanup(patcher.stop)
        for name in ("RIG_LOCK_PARENT_ACTOR", "RIG_LOCK_PARENT_NONCE", "RIG_LOCK_PARENT_FD"):
            os.environ.pop(name, None)
        patcher = patch.object(proof, "LIB", self.root)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        os.umask(self.previous)
        self.temporary.cleanup()

    def call(self, timeout=30):
        return proof.run_recovery(
            Path("/b"), Path("/s"), Path("/j"), b'{"schema": 1}', self.root, timeout, self.log
        )

    def test_the_documented_command_gets_its_request_on_stdin_and_stderr_goes_to_a_private_log(
        self,
    ):
        code, out = self.call()
        self.assertEqual((code, out), (0, b'{"ok": 1}\n'))
        record = json.loads(self.record.read_text())
        self.assertEqual(record["argv"], ["/b", "/s", "/j"])
        self.assertEqual(record["stdin"], '{"schema": 1}')
        self.assertEqual(self.log.read_text(), "stub stderr line\n")
        self.assertEqual(stat.S_IMODE(self.log.stat().st_mode), 0o600)

    def test_a_refusal_exit_code_is_returned_not_raised(self):
        with patch.dict(os.environ, {"STUB_EXIT": "1"}):
            self.assertEqual(self.call()[0], 1)

    def test_without_a_parent_claim_the_recovery_locks_a_private_file(self):
        self.call()
        self.assertEqual(
            json.loads(self.record.read_text())["lock"], str(self.root / "recovery.lock")
        )

    def test_with_a_parent_claim_the_lock_environment_and_descriptor_pass_through(self):
        read, write = os.pipe()
        self.addCleanup(os.close, read)
        self.addCleanup(os.close, write)
        claim = {
            "RIG_LOCK_PARENT_ACTOR": "runner",
            "RIG_LOCK_PARENT_NONCE": "0" * 32,
            "RIG_LOCK_PARENT_FD": str(write),
        }
        with patch.dict(os.environ, claim):
            self.call()
        record = json.loads(self.record.read_text())
        self.assertIsNone(record["lock"])
        self.assertTrue(record["fd_open"])

    def test_a_timeout_terminates_the_recovery_and_never_kills_it(self):
        with (
            patch.dict(os.environ, {"STUB_SLEEP": "1"}),
            patch.object(proof, "STOP_GRACE", 10),
            self.assertRaises(subprocess.TimeoutExpired),
        ):
            self.call(timeout=1)
        self.assertEqual(Path(str(self.record) + ".term").read_text(), "terminated")


class ReasonsTest(unittest.TestCase):
    def test_the_closed_refusal_set_matches_the_recovery_source(self):
        source = (HERE.parent / "lib/wallet_fixture_recovery.py").read_text()
        found = set(re.findall(r'(?:Refusal|refusing)\("([a-z]+)"\)', source))
        found |= set(re.findall(r'"reason": "([a-z]+)"', source))
        self.assertEqual(found, proof.REASONS)


if __name__ == "__main__":
    unittest.main()
