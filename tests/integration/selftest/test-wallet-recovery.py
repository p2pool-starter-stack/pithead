"""Operator recovery of a retained wallet fixture: success, resumption and fixed refusals."""

import importlib.util
import json
import shutil
import subprocess
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


existing = module("fixture_tests", HERE / "test-wallet-fixture.py")
fixture = existing.fixture
retire = module("retire", HERE.parent / "lib/wallet_fixture_supersession.py")
recovery = module("recovery", HERE.parent / "lib/wallet_fixture_recovery.py")
SECRETS = ("dummy-address", "dummy-view-key", "dummy-password", "dummy-user")


class Steps:
    """The shell-only steps, recorded and failable."""

    def __init__(self):
        self.calls = []
        self.fail = {}

    def step(self, name):
        self.calls.append(name)
        if name in self.fail:
            raise self.fail[name]

    def lock_check(self):
        self.step("lock")

    def start(self):
        self.step("start")

    def ready(self):
        self.step("ready")


class RecoveryBase(unittest.TestCase):
    def setUp(self):
        existing.FixtureTest.setUp(self)
        self.live = SimpleNamespace(
            volume=False, wallet=True, helpers=b"", proofs=[], import_error=None
        )
        self.mock_docker.stop()
        self.mock_docker = patch.object(fixture, "docker", self.wrapped())
        self.mock_docker.start()
        self.steps = Steps()

    tearDown = existing.FixtureTest.tearDown
    capture = existing.FixtureTest.capture

    def wrapped(self):
        base, live = self.docker, self.live

        def call(*args, **kwargs):
            if args[:2] == ("volume", "ls"):
                base.calls.append(args)
                return subprocess.CompletedProcess(
                    args, 0, (fixture.VOLUME + "\n").encode() if live.volume else b""
                )
            if args[0] == "ps" and "name=" in args[-1]:
                base.calls.append(args)
                return subprocess.CompletedProcess(args, 0, live.helpers)
            if args[0] == "run" and args[-1] == retire.OPEN_COPY:
                base.calls.append(args)
                return subprocess.CompletedProcess(args, 0, json.dumps(live.proofs.pop(0)).encode())
            if args[0] == "run" and "-print -quit" in args[-1]:
                base.calls.append(args)
                return subprocess.CompletedProcess(
                    args, 0, b"payout-wallet.keys\n" if live.wallet else b""
                )
            if args[0] == "run" and "--no-same-owner" in args[-1] and live.import_error:
                base.calls.append(args)
                raise live.import_error
            return base(*args, **kwargs)

        return call

    def prepare(self, receipt="ARMED"):
        self.docker.item["State"]["Running"] = True
        self.docker.contents = existing.archive()
        self.directory = self.capture()
        self.original = self.docker.contents
        self.job = self.root / "12"
        shutil.rmtree(self.job, ignore_errors=True)
        self.job.mkdir()
        fixture.receipt(self.job, "ARMED")
        if receipt == "NOT_PROVEN":
            fixture.receipt(self.job, "NOT_PROVEN")
        self.request = {
            "schema": 1,
            "original_job": 12,
            "original_commit": "a" * 40,
            "recovery_issues": ["bench-ci#2019", "pithead#3483"],
        }
        self.docker.contents = existing.archive({"payout-wallet": b"a cache that moved on"})
        self.saved = {p.name: p.read_bytes() for p in self.directory.iterdir()}
        self.docker.calls.clear()

    def recover(self, raw=None):
        raw = json.dumps(self.request).encode() if raw is None else raw
        return recovery.recover(
            fixture,
            retire,
            self.directory,
            self.baseline,
            self.job,
            raw,
            self.steps,
            self.root / "branch",
        )

    def refused(self, reason, **kwargs):
        with self.assertRaises(recovery.Refusal) as context:
            self.recover(**kwargs)
        self.assertEqual(context.exception.reason, reason)

    def receipt(self):
        return (self.job / "wallet-fixture-restore.state").read_bytes()

    def imports(self):
        return [
            c
            for c in self.docker.calls
            if c[0] == "run" and "--no-same-owner" in c[-1] and c[-1] != retire.OPEN_COPY
        ]

    def assert_untouched(self, receipt=b"ARMED\n"):
        self.assertEqual(self.receipt(), receipt)
        for name, contents in self.saved.items():
            self.assertEqual((self.directory / name).read_bytes(), contents)
        self.assertFalse(self.imports())
        self.assertFalse(list(self.root.glob("pithead-wallet-proof-*")))


class RecoveryTest(RecoveryBase):
    def test_success_restores_proves_and_verifies(self):
        self.prepare()
        verdict = self.recover()
        self.assertEqual(self.steps.calls, ["lock", "start", "ready", "lock"])
        self.assertEqual(self.receipt(), b"VERIFIED\n")
        self.assertEqual(self.docker.contents, self.original)
        self.assertEqual({p.name for p in self.directory.iterdir()}, {"state.json"})
        self.assertEqual(
            fixture.load(self.directory, self.baseline, cleanup_only=True)["stage"], "ready"
        )
        recovery.validate_verdict(verdict)
        self.assertEqual(verdict["status"], "RESTORED")
        self.assertEqual(verdict["request"], self.request)
        self.assertEqual(verdict["proof"]["method"], "no_volume")
        self.assertFalse(verdict["proof"]["live_identity_proven"])
        text = json.dumps(verdict)
        for secret in (*SECRETS, str(self.root)):
            self.assertNotIn(secret, text)

    def test_ready_is_written_before_verified_and_never_skipped(self):
        self.prepare()
        stages = []
        real = fixture.receipt

        def spy(directory, stage):
            stages.append(stage)
            return real(directory, stage)

        with patch.object(fixture, "receipt", spy):
            self.recover()
        self.assertEqual(stages, ["READY", "VERIFIED"])
        self.prepare()
        with self.assertRaises(ValueError):
            fixture.receipt(self.job, "VERIFIED")
        self.assertEqual(self.receipt(), b"ARMED\n")

    def test_not_proven_receipt_reaches_ready_only_through_the_full_proof(self):
        self.prepare("NOT_PROVEN")
        with self.assertRaises(ValueError):
            fixture.receipt(self.job, "READY")
        seen = []
        real = recovery.ready_from_not_proven

        def spy(fx, job):
            real(fx, job)
            seen.append((job / "wallet-fixture-restore.state").read_bytes())

        with patch.object(recovery, "ready_from_not_proven", spy):
            self.recover()
        self.assertEqual(seen, [b"READY\n"])
        self.assertEqual(self.receipt(), b"VERIFIED\n")
        self.prepare("NOT_PROVEN")
        self.steps.fail["ready"] = subprocess.CalledProcessError(1, "ready")
        self.refused("readiness")
        self.assertEqual(self.receipt(), b"NOT_PROVEN\n")
        self.assertTrue((self.directory / "wallet.tar").exists())

    def test_interrupted_import_resumes_from_restoring(self):
        self.prepare()
        self.live.import_error = InterruptedError("signal")
        self.refused("interrupted")
        self.assertEqual(
            json.loads((self.directory / "state.json").read_text())["stage"], "restoring"
        )
        self.assertEqual(self.receipt(), b"ARMED\n")
        self.assertTrue((self.directory / "wallet.tar").exists())
        self.assertTrue((self.directory / "image.tar").exists())
        self.assertEqual(self.steps.calls, ["lock"])
        names = [c[-1] for c in self.docker.calls if c[0] == "ps" and "name=" in c[-1]]
        self.assertTrue(any(name.endswith("-import$") for name in names))
        self.live.import_error = None
        verdict = self.recover()
        self.assertEqual(verdict["status"], "RESTORED")
        self.assertEqual(self.receipt(), b"VERIFIED\n")
        self.assertEqual(self.docker.contents, self.original)

    def test_corrupt_archive_refuses_before_any_docker_call(self):
        self.prepare()
        (self.directory / "wallet.tar").write_bytes(self.saved["wallet.tar"] + b"corrupt")
        self.refused("archive")
        self.saved["wallet.tar"] = (self.directory / "wallet.tar").read_bytes()
        self.assertFalse(self.docker.calls)
        self.assert_untouched()
        (self.directory / "wallet.tar").write_bytes(self.saved["wallet.tar"][:-7])
        (self.directory / "image.tar").write_bytes(b"not the pinned image")
        self.saved["image.tar"] = b"not the pinned image"
        self.refused("archive")
        self.assertFalse(self.docker.calls)
        with (self.directory / "wallet.tar").open("ab") as stream:
            stream.truncate(2 * 1024**3 + 1024**2 + 1)
        self.refused("evidence")
        self.assertFalse(self.docker.calls)

    def test_a_changed_baseline_wallet_identity_refuses_before_any_docker_call(self):
        self.prepare()
        original = self.env.read_text()
        for field in ("MONERO_WALLET_ADDRESS", "MONERO_VIEW_KEY", "PAYOUT_SCAN_HEIGHT"):
            self.env.write_text(original.replace(field + "=", field + "=changed-"))
            self.refused("identity")
            self.assertFalse(self.docker.calls)
            self.assert_untouched()
        self.env.write_text(original)

    def test_a_live_wallet_that_is_not_the_snapshots_refuses_and_keeps_both(self):
        self.prepare()
        self.live.volume = True
        self.docker.contents = existing.archive({"payout-wallet.keys": b"other encrypted keys"})
        differing = self.docker.contents
        first = {"address_fingerprint": "c" * 64, "view_key_fingerprint": "d" * 64}
        self.live.proofs = [first, {**first, "view_key_fingerprint": "e" * 64}]
        self.refused("identity")
        self.assert_untouched()
        self.assertEqual(self.docker.contents, differing)
        self.assertTrue(self.docker.item["State"]["Running"])
        self.assertEqual(self.steps.calls, ["lock"])

    def test_a_live_wallet_with_the_same_keys_or_the_same_identity_is_overwritten(self):
        self.prepare()
        self.live.volume = True
        self.docker.contents = existing.archive({"payout-wallet": b"newer cache"})
        self.assertEqual(self.recover()["proof"]["method"], "encrypted_keys")
        self.assertEqual(self.docker.contents, self.original)
        self.prepare()
        self.live.volume = True
        self.docker.contents = existing.archive({"payout-wallet.keys": b"re-encrypted keys"})
        same = {"address_fingerprint": "c" * 64, "view_key_fingerprint": "d" * 64}
        self.live.proofs = [same, same]
        verdict = self.recover()
        self.assertEqual(verdict["proof"]["method"], "isolated_open")
        self.assertTrue(verdict["proof"]["live_identity_proven"])
        self.assertEqual(self.docker.contents, self.original)
        self.prepare()
        self.live.volume = True
        self.live.wallet = False
        self.assertEqual(self.recover()["proof"]["method"], "empty_volume")

    def test_a_superseded_fixture_refuses(self):
        self.prepare()
        request = {
            "schema": 1,
            "original_job": 12,
            "original_commit": "a" * 40,
            "successor_job": 13,
            "successor_commit": "b" * 40,
            "recovery_issues": ["bench-ci#1249"],
        }
        self.docker.contents = self.original
        retire.supersede(
            fixture, self.directory, self.baseline, self.job, json.dumps(request).encode()
        )
        self.docker.contents = existing.archive({"payout-wallet": b"a cache that moved on"})
        self.saved = {p.name: p.read_bytes() for p in self.directory.iterdir()}
        self.docker.calls.clear()
        self.refused("superseded")
        self.assertFalse(self.docker.calls)
        self.assert_untouched()
        self.assertEqual(self.steps.calls, [])

    def test_an_active_helper_container_refuses(self):
        self.prepare()
        self.live.helpers = b"0123456789ab\n"
        self.refused("helper")
        self.assert_untouched()
        self.assertEqual(self.steps.calls, [])

    def test_unrecoverable_receipts_and_job_directories_refuse(self):
        self.prepare()
        fixture.receipt(self.job, "READY")
        fixture.receipt(self.job, "VERIFIED")
        self.refused("receipt")
        self.assertFalse(self.docker.calls)
        (self.job / "wallet-fixture-restore.state").unlink()
        self.refused("receipt")
        (self.job / "wallet-fixture-restore.state").symlink_to(self.root / "absent")
        self.refused("receipt")
        (self.job / "wallet-fixture-restore.state").unlink()
        fixture.receipt(self.job, "ARMED")
        self.job.chmod(0o777)
        self.refused("evidence")
        self.job.chmod(0o700)
        self.directory.chmod(0o755)
        self.refused("evidence")
        self.directory.chmod(0o700)
        self.request["original_job"] = 13
        self.refused("evidence")
        self.assertFalse(self.docker.calls)

    def test_a_failed_start_or_gate_keeps_the_fence_and_retries_exactly(self):
        for name, reason in (("start", "startup"), ("ready", "readiness")):
            with self.subTest(name):
                self.prepare()
                self.steps.fail[name] = subprocess.CalledProcessError(1, name)
                self.refused(reason)
                self.assertEqual(self.receipt(), b"ARMED\n")
                self.assertEqual(
                    json.loads((self.directory / "state.json").read_text())["stage"],
                    "import_verified",
                )
                self.assertTrue((self.directory / "wallet.tar").exists())
                self.assertEqual(len(self.imports()), 1)
                self.steps.fail.clear()
                self.assertEqual(self.recover()["status"], "RESTORED")
                self.assertEqual(self.receipt(), b"VERIFIED\n")
                self.job.rename(self.root / f"done-{name}")

    def test_an_interrupt_or_lost_lock_stops_the_run_unchanged(self):
        self.prepare()
        self.steps.fail["start"] = InterruptedError("signal")
        self.refused("interrupted")
        self.assertEqual(self.receipt(), b"ARMED\n")
        self.steps.fail.clear()
        self.steps.fail["lock"] = subprocess.CalledProcessError(1, "lock-verify")
        self.refused("lock")
        self.assertEqual(self.receipt(), b"ARMED\n")
        self.assertEqual(self.steps.calls[-1], "lock")

    def test_a_failure_after_ready_resumes_and_still_ends_verified(self):
        self.prepare()
        with patch.object(fixture, "cleanup", side_effect=ValueError("disk")):
            self.refused("seal")
        self.assertEqual(self.receipt(), b"READY\n")
        self.assertTrue((self.directory / "wallet.tar").exists())
        verdict = self.recover()
        self.assertEqual(verdict["status"], "RESTORED")
        self.assertEqual(self.receipt(), b"VERIFIED\n")

    def test_a_completed_cleanup_without_a_verified_receipt_resumes_without_importing(self):
        self.prepare()
        fixture.restore(self.directory, self.baseline, self.root / "branch")
        fixture.receipt(self.job, "READY")
        fixture.cleanup(self.directory, self.baseline)
        self.docker.calls.clear()
        verdict = self.recover()
        self.assertEqual(verdict["proof"]["method"], "resumed")
        self.assertEqual(self.receipt(), b"VERIFIED\n")
        self.assertFalse(self.imports())


if __name__ == "__main__":
    unittest.main()
