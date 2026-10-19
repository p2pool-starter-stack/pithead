"""The recovery interface: request and verdict schemas, the CLI, the rig lock and the shell steps."""

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

HERE = Path(__file__).resolve().parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


base = module("recovery_tests", HERE / "test-wallet-recovery.py")
fixture, retire, recovery = base.fixture, base.retire, base.recovery
SECRETS = ("dummy-address", "dummy-view-key", "dummy-password", "dummy-user")


class InterfaceTest(base.RecoveryBase):
    def test_malformed_requests_refuse_before_any_work(self):
        self.prepare()
        good = json.dumps(self.request)
        bad = [
            b"",
            b"[]",
            b"not json",
            good.replace('"schema": 1', '"schema": 2').encode(),
            good.replace('"schema": 1', '"schema": true').encode(),
            json.dumps({**self.request, "extra": 1}).encode(),
            good[:-1].encode() + b', "schema": 1}',
            json.dumps({**self.request, "original_commit": "A" * 40}).encode(),
            json.dumps({**self.request, "original_job": 0}).encode(),
            json.dumps({**self.request, "recovery_issues": []}).encode(),
            json.dumps({**self.request, "recovery_issues": ["x#1"]}).encode(),
            json.dumps({**self.request, "recovery_issues": ["pithead#1", "pithead#1"]}).encode(),
            b" " * 16385,
        ]
        for raw in bad:
            with self.subTest(raw=raw[:40]):
                self.refused("request", raw=raw)
        self.assertFalse(self.docker.calls)
        self.assert_untouched()

    def test_verdict_schema_is_closed(self):
        self.prepare()
        verdict = self.recover()
        recovery.validate_verdict(verdict)
        mutations = [
            lambda v: v.update(extra=1),
            lambda v: v.update(status="REFUSED"),
            lambda v: v.update(receipt_fingerprint="0" * 64),
            lambda v: v["proof"].update(address="dummy-address"),
            lambda v: v["proof"].update(method="other"),
            lambda v: v["proof"].update(wallet_ready=False),
            lambda v: v["proof"].update(import_verified=1),
            lambda v: v["proof"].update(live_identity_proven=True),
            lambda v: v["proof"].update(archive_fingerprint="ABC"),
            lambda v: v["proof"].pop("keys_fingerprint"),
            lambda v: v["request"].update(original_job="12"),
        ]
        for mutate in mutations:
            copy = json.loads(json.dumps(verdict))
            mutate(copy)
            with self.assertRaises(ValueError):
                recovery.validate_verdict(copy)

    def test_cli_prints_one_object_and_a_fixed_exit_for_each_outcome(self):
        self.prepare()
        modules = {"wallet-fixture.py": fixture, "wallet_fixture_supersession.py": retire}
        argv = [str(self.baseline), str(self.directory), str(self.job)]
        raw = json.dumps(self.request).encode()
        env = {"RIG_LOCK_FILE": str(self.root / "rig.lock")}
        with (
            patch.object(recovery, "load_module", lambda name, filename: modules[filename]),
            patch.dict(os.environ, env),
        ):
            code, text = recovery.run(argv, raw, self.steps)
            self.assertEqual((code, json.loads(text)["status"]), (0, "RESTORED"))
            code, text = recovery.run(argv[:2], raw, self.steps)
            self.assertEqual(
                (code, text), (1, '{"schema": 1, "status": "REFUSED", "reason": "request"}')
            )
            code, text = recovery.run(argv, raw, self.steps)
            self.assertEqual(code, 1)
            self.assertEqual(
                json.loads(text), {"schema": 1, "status": "REFUSED", "reason": "receipt"}
            )
            with (
                patch.object(recovery, "recover", side_effect=RuntimeError("secret path")),
                patch("sys.stderr", io.StringIO()) as log,
            ):
                code, text = recovery.run(argv, raw, self.steps)
            self.assertEqual(json.loads(text)["reason"], "internal")
            self.assertNotIn("secret path", text + log.getvalue())
            self.assertIn("RuntimeError", log.getvalue())
            with patch.object(recovery, "recover", side_effect=InterruptedError):
                self.assertEqual(
                    json.loads(recovery.run(argv, raw, self.steps)[1])["reason"], "interrupted"
                )

    def test_the_rig_lock_is_exclusive_unless_the_runner_holds_it(self):
        path = self.root / "rig.lock"
        with patch.dict(os.environ, {"RIG_LOCK_FILE": str(path)}):
            os.environ.pop("RIG_LOCK_PARENT_ACTOR", None)
            os.environ.pop("RIG_LOCK_PARENT_NONCE", None)
            first = recovery.hold_bench_lock()
            self.assertIsNotNone(first)
            with self.assertRaises(recovery.Refusal) as context:
                recovery.hold_bench_lock()
            self.assertEqual(context.exception.reason, "busy")
            os.close(first)
            os.close(recovery.hold_bench_lock())
            path.unlink()
            path.symlink_to(self.root / "elsewhere")
            with self.assertRaises(recovery.Refusal):
                recovery.hold_bench_lock()
        with patch.dict(
            os.environ, {"RIG_LOCK_PARENT_ACTOR": "runner", "RIG_LOCK_FILE": str(path)}
        ):
            self.assertIsNone(recovery.hold_bench_lock())

    def test_run_holds_the_rig_lock_for_the_whole_recovery_and_releases_it(self):
        self.prepare()
        modules = {"wallet-fixture.py": fixture, "wallet_fixture_supersession.py": retire}
        argv = [str(self.baseline), str(self.directory), str(self.job)]
        raw = json.dumps(self.request).encode()
        during = []
        start = self.steps.start

        def held_start():
            with self.assertRaises(recovery.Refusal) as context:
                recovery.hold_bench_lock()
            during.append(context.exception.reason)
            start()

        self.steps.start = held_start
        with (
            patch.object(recovery, "load_module", lambda name, filename: modules[filename]),
            patch.dict(os.environ, {"RIG_LOCK_FILE": str(self.root / "rig.lock")}),
        ):
            os.environ.pop("RIG_LOCK_PARENT_ACTOR", None)
            os.environ.pop("RIG_LOCK_PARENT_NONCE", None)
            holder = recovery.hold_bench_lock()
            code, text = recovery.run(argv, raw, self.steps)
            self.assertEqual((code, json.loads(text)["reason"]), (1, "busy"))
            self.assertEqual((self.docker.calls, self.steps.calls, during), ([], [], []))
            self.assert_untouched()
            os.close(holder)
            self.assertEqual(recovery.run(argv, raw, self.steps)[0], 0)
            self.assertEqual(during, ["busy"])
            os.close(recovery.hold_bench_lock())


class HelperStepsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def script(self, body):
        path = self.root / "helper.sh"
        path.write_text(body)
        return patch.object(recovery, "HELPER", path)

    def test_the_action_and_baseline_reach_the_helper_and_a_failure_is_an_error(self):
        out = self.root / "args"
        with self.script(f'printf "%s %s" "$1" "$2" >{out}\nexit 0\n'):
            recovery.HelperSteps("/baseline").start()
        self.assertEqual(out.read_text(), "start /baseline")
        with self.script("exit 3\n"), self.assertRaises(subprocess.CalledProcessError):
            recovery.HelperSteps("/baseline").ready()

    def test_the_helper_runs_under_a_normal_umask_not_the_wrapper_private_one(self):
        out = self.root / "umask"
        previous = os.umask(0o077)
        try:
            with self.script(f"umask >{out}\n"):
                recovery.HelperSteps("/baseline").start()
        finally:
            os.umask(previous)
        self.assertEqual(out.read_text().strip(), "0022")

    def test_a_vanished_process_group_does_not_mask_the_original_interrupt(self):
        process = Mock(pid=1)
        process.wait.side_effect = [
            InterruptedError("signal"),
            subprocess.TimeoutExpired("x", 30),
            0,
        ]
        with (
            patch.object(recovery.subprocess, "Popen", return_value=process),
            patch.object(recovery.os, "killpg", side_effect=ProcessLookupError),
            self.assertRaises(InterruptedError),
        ):
            recovery.HelperSteps("/baseline").run("start", 5)
        self.assertEqual(process.wait.call_count, 3)

    def test_helper_output_never_reaches_the_verdict_stream(self):
        helper = self.root / "helper.sh"
        helper.write_text("echo log-line\necho err-line >&2\n")
        code = (
            "import importlib.util, sys; "
            f"spec = importlib.util.spec_from_file_location('r', '{HERE.parent / 'lib/wallet_fixture_recovery.py'}'); "
            "r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r); "
            f"r.HELPER = '{helper}'; r.HelperSteps('/baseline').start()"
        )
        done = subprocess.run(  # noqa: S603
            [sys.executable, "-c", code], capture_output=True, text=True, check=True
        )
        self.assertEqual(done.stdout, "")
        self.assertIn("log-line", done.stderr)

    def test_a_timeout_stops_the_whole_process_group(self):
        pid = self.root / "pid"
        with self.script(f"sleep 60 &\necho $! >{pid}\nwait\n"):
            with self.assertRaises(subprocess.TimeoutExpired):
                recovery.HelperSteps("/baseline").run("start", 1)
        child = int(pid.read_text())
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            with contextlib.suppress(ProcessLookupError):
                os.kill(child, 0)
                time.sleep(0.1)
                continue
            break
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)


if __name__ == "__main__":
    unittest.main()
