"""Interrupted capture must prove helper exit before restarting the live wallet."""

import importlib.util
import io
import json
import subprocess
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


existing = load("supersession_tests", HERE / "test-wallet-supersession.py")
fixture, retirement = existing.fixture, existing.retire
proof = load("proof", HERE.parent / "tools/prove-wallet-supersession.py")


class CleanupFailureTest(unittest.TestCase):
    setUp = existing.SupersessionTest.setUp
    tearDown = existing.SupersessionTest.tearDown
    capture = existing.SupersessionTest.capture
    prepare = existing.SupersessionTest.prepare
    run_retirement = existing.SupersessionTest.run_retirement
    proof_docker = existing.SupersessionTest.proof_docker

    def failing_capture(self, suffix, failure, cleanup):
        original = self.proof_docker([])
        self.active = False
        self.events = []

        def docker(*args, **kwargs):
            self.events.append(args)
            self.assertGreater(kwargs.get("timeout", 0), 0)
            if args[0] == "run" and any(value.endswith(suffix) for value in args):
                self.active = True
                raise failure
            if args[0] == "ps" and "name=" in args[-1]:
                return subprocess.CompletedProcess(args, 0, b"helper" if self.active else b"")
            if args[0] == "kill" and args[-1].endswith(suffix):
                self.assertEqual(args[2], "TERM")
                return subprocess.CompletedProcess(args, 0, b"")
            if args[0] == "wait":
                if cleanup == "timeout":
                    raise subprocess.TimeoutExpired("docker wait", 600)
                if cleanup == "refusal":
                    raise subprocess.CalledProcessError(1, ["docker", "wait"])
                if cleanup == "success":
                    self.active = False
                return subprocess.CompletedProcess(args, 0, b"0")
            if args[0] == "rm":
                return subprocess.CompletedProcess(args, 1 if self.active else 0, b"")
            return original(*args, **kwargs)

        return docker

    def test_supersession_cleanup_failure_keeps_live_stopped_and_evidence_intact(self):
        for failure in (InterruptedError("interrupted"), subprocess.TimeoutExpired("capture", 180)):
            for cleanup in ("timeout", "refusal", "still-present"):
                with self.subTest(failure=type(failure).__name__, cleanup=cleanup):
                    self.prepare()
                    before = {p.name: p.read_bytes() for p in self.directory.iterdir()}
                    docker = self.failing_capture("identity-capture", failure, cleanup)
                    with patch.object(fixture, "docker", docker):
                        with self.assertRaises((ValueError, subprocess.SubprocessError)):
                            self.run_retirement()
                    self.assertTrue(self.active)
                    self.assertFalse(self.docker.item["State"]["Running"])
                    self.assertFalse(any(event[0] == "start" for event in self.events))
                    self.assertEqual(
                        {p.name: p.read_bytes() for p in self.directory.iterdir()}, before
                    )
                    self.assertEqual(
                        (self.job / "wallet-fixture-restore.state").read_bytes(), b"ARMED\n"
                    )
                    self.assertFalse((self.directory / "supersession.json").exists())
                    self.job.rename(self.root / f"failed-{type(failure).__name__}-{cleanup}")

    def test_actual_lifecycle_capture_restart_requires_proved_helper_cleanup(self):
        baseline_before = self.env.read_bytes()
        for cleanup in ("timeout", "refusal", "still-present", "success"):
            with self.subTest(cleanup=cleanup):
                self.docker.item["State"]["Running"] = True
                docker = self.failing_capture("-capture", InterruptedError("interrupted"), cleanup)
                with (
                    patch.object(fixture, "docker", docker),
                    patch.object(proof, "load", side_effect=[fixture, retirement]),
                    patch.object(proof, "wait_prepared"),
                ):
                    code, result = proof.run_proof(self.baseline)
                self.assertEqual(code, 1)
                self.assertEqual(result["failed_stage"], "capture")
                self.assertFalse(result["identity_proven"])
                self.assertNotIn("interrupted", json.dumps(result))
                starts = [i for i, event in enumerate(self.events) if event[0] == "start"]
                if cleanup == "success":
                    self.assertFalse(self.active)
                    self.assertTrue(self.docker.item["State"]["Running"])
                    self.assertEqual(len(starts), 1)
                    self.assertLess(
                        next(i for i, e in enumerate(self.events) if e[0] == "wait"), starts[0]
                    )
                else:
                    self.assertTrue(self.active)
                    self.assertFalse(self.docker.item["State"]["Running"])
                    self.assertFalse(starts)
                self.assertEqual(self.env.read_bytes(), baseline_before)
                self.assertFalse(list(self.root.rglob("supersession.json")))

    def test_streamed_capture_uses_the_same_operation_without_adjacent_import(self):
        source = "\n".join(
            (HERE.parent / "lib" / name).read_text()
            for name in ("wallet_fixture_capture.py", "wallet-fixture.py")
        )
        namespace = {"__name__": "streamed_fixture", "__file__": "<stdin>"}
        exec(compile(source, "streamed-capture", "exec"), namespace)  # noqa: S102 -- trusted repository source, like the wrapper's stdin transport.
        namespace["docker"] = self.docker
        with redirect_stdout(io.StringIO()) as output:
            namespace["capture"](self.baseline)
        directory = Path(output.getvalue().strip())
        self.assertTrue((directory / "state.json").exists())
        self.assertTrue(self.docker.item["State"]["Running"])


if __name__ == "__main__":
    unittest.main()
