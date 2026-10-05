"""Wrapper-owned retirement preserves restoration evidence and proves wallet identity."""

import importlib.util
import io
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path
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


class SupersessionTest(unittest.TestCase):
    def setUp(self):
        existing.FixtureTest.setUp(self)
        self.mock_docker.stop()
        self.mock_docker = patch.object(fixture, "docker", self.proof_docker([]))
        self.mock_docker.start()

    tearDown = existing.FixtureTest.tearDown
    capture = existing.FixtureTest.capture

    def prepare(self):
        self.docker.contents = existing.archive()
        self.directory = self.capture()
        self.job = self.root / "12"
        self.job.mkdir()
        fixture.receipt(self.job, "ARMED")
        self.request = {
            "schema": 1,
            "original_job": 12,
            "original_commit": "a" * 40,
            "successor_job": 13,
            "successor_commit": "b" * 40,
            "recovery_issues": ["bench-ci#1249", "bench-ci#1264"],
        }
        self.saved = {p.name: p.read_bytes() for p in self.directory.iterdir()}
        self.docker.calls.clear()

    def run_retirement(self):
        return retire.supersede(
            fixture, self.directory, self.baseline, self.job, json.dumps(self.request).encode()
        )

    def assert_preserved(self, success=False):
        self.assertEqual((self.job / "wallet-fixture-restore.state").read_bytes(), b"ARMED\n")
        for name, contents in self.saved.items():
            self.assertEqual((self.directory / name).read_bytes(), contents)
        self.assertEqual((self.directory / "supersession.json").exists(), success)
        self.assertTrue(self.docker.item["State"]["Running"])
        self.assertFalse(list(self.root.glob("pithead-wallet-proof-*")))
        self.assertFalse(
            any(
                "--no-same-owner" in c[-1]
                for c in self.docker.calls
                if c[0] == "run" and c[-1] != retire.OPEN_COPY
            )
        )
        self.assertFalse(any(c[0] == "kill" and c[2] != "TERM" for c in self.docker.calls))

    def test_encrypted_identity_and_idempotent_retry_preserve_original_evidence(self):
        self.prepare()
        result = self.run_retirement()
        self.assertEqual(result["status"], "SUPERSEDED")
        self.assertEqual(result["proof"]["method"], "encrypted_keys")
        self.assertTrue(result["proof"]["identity_proven"])
        self.assertTrue(result["proof"]["encrypted_keys_match"])
        before = len(self.docker.calls)
        self.assertEqual(self.run_retirement(), result)
        self.assertEqual(len(self.docker.calls), before)
        self.assertEqual((self.directory / "supersession.json").stat().st_mode & 0o777, 0o600)
        self.assert_preserved(True)
        with self.assertRaisesRegex(ValueError, "superseded"):
            fixture.restore(self.directory, self.baseline, self.root / "branch")
        with self.assertRaisesRegex(ValueError, "superseded"):
            fixture.cleanup(self.directory, self.baseline)
        with self.assertRaises(ValueError):
            fixture.receipt(self.job, "SUPERSEDED")
        self.request["successor_commit"] = "c" * 40
        with self.assertRaisesRegex(ValueError, "mismatched"):
            self.run_retirement()

    def proof_docker(self, proofs):
        original = self.docker
        sequence = iter(proofs)

        def call(*args, **kwargs):
            if args[0] == "run" and args[-1] == retire.OPEN_COPY:
                original.calls.append(args)
                value = next(sequence)
                if isinstance(value, Exception):
                    raise value
                return subprocess.CompletedProcess(args, 0, json.dumps(value).encode())
            if args[0] == "ps" and "name=" in args[-1]:
                original.calls.append(args)
                return subprocess.CompletedProcess(args, 0, b"")
            return original(*args, **kwargs)

        return call

    def differing_keys(self):
        self.docker.contents = existing.archive(
            {"payout-wallet.keys": b"other encrypted representation"}
        )

    def test_different_encryption_requires_both_primary_address_and_view_key(self):
        self.prepare()
        self.differing_keys()
        equal = {"address_fingerprint": "c" * 64, "view_key_fingerprint": "d" * 64}
        with patch.object(fixture, "docker", self.proof_docker([equal, equal])):
            result = self.run_retirement()
        self.assertFalse(result["proof"]["encrypted_keys_match"])
        self.assertTrue(result["proof"]["address_match"])
        self.assertTrue(result["proof"]["view_key_match"])
        runs = [c for c in self.docker.calls if c[-1] == retire.OPEN_COPY]
        self.assertEqual(len(runs), 2)
        for command in runs:
            self.assertNotIn("--mount", command)
            self.assertNotIn("--volume", command)
            self.assertEqual(command[command.index("--network") + 1], "none")
            self.assertIn("--read-only", command)
            self.assertIn("--tmpfs", command)
            self.assertEqual(command[command.index("--user") + 1], "1000:1000")
        self.assert_preserved(True)

    def test_different_wallet_or_view_key_refuses_and_restarts_live_wallet(self):
        for field in ("address_fingerprint", "view_key_fingerprint"):
            with self.subTest(field=field):
                self.prepare()
                self.differing_keys()
                first = {"address_fingerprint": "c" * 64, "view_key_fingerprint": "d" * 64}
                second = {**first, field: "e" * 64}
                with patch.object(fixture, "docker", self.proof_docker([first, second])):
                    with self.assertRaisesRegex(ValueError, "address or view key"):
                        self.run_retirement()
                self.assert_preserved()
                # Retain each refusal's original evidence; use a new job directory next time.
                self.job.rename(self.root / ("failed-" + field))

    def test_archive_digest_manifest_and_image_corruption_refuse_before_stop(self):
        self.prepare()
        for name in ("wallet.tar", "image.tar"):
            original = (self.directory / name).read_bytes()
            (self.directory / name).write_bytes(original + b"corrupt")
            with self.assertRaises(ValueError):
                self.run_retirement()
            self.assertFalse(self.docker.calls)
            (self.directory / name).write_bytes(original)
            with (self.directory / name).open("ab") as stream:
                stream.truncate(
                    (2 * 1024**3 + 1024**2 if name == "wallet.tar" else 4 * 1024**3) + 1
                )
            with self.assertRaisesRegex(ValueError, "exceeds its limit"):
                self.run_retirement()
            (self.directory / name).write_bytes(original)
        state = json.loads((self.directory / "state.json").read_bytes())
        state["contents"]["payout-wallet.keys"][2] = "f" * 64
        fixture.write_state(self.directory, state)
        with self.assertRaises(ValueError):
            self.run_retirement()
        self.assertFalse(self.docker.calls)

    def test_unsafe_ownership_modes_symlinks_and_stages_refuse(self):
        self.prepare()
        for path, mode in (
            (self.directory, 0o700),
            (self.directory / "state.json", 0o600),
            (self.directory / "wallet.tar", 0o600),
            (self.job / "wallet-fixture-restore.state", 0o600),
        ):
            path.chmod(0o777)
            with self.assertRaises(ValueError):
                self.run_retirement()
            path.chmod(mode)
        receipt = self.job / "wallet-fixture-restore.state"
        receipt.unlink()
        receipt.symlink_to(self.root / "absent")
        with self.assertRaises(OSError):
            self.run_retirement()
        receipt.unlink()
        fixture.receipt(self.job, "ARMED")
        for stage in ("restoring", "ready"):
            state = json.loads((self.directory / "state.json").read_bytes())
            state["stage"] = stage
            fixture.write_state(self.directory, state)
            with self.assertRaises(ValueError):
                self.run_retirement()
        self.assertFalse(self.docker.calls)

    def test_wallet_open_timeout_or_invalid_response_never_records_retirement(self):
        self.prepare()
        self.differing_keys()
        for result in (
            subprocess.TimeoutExpired("docker", 660),
            {"address_fingerprint": "c" * 64},
            {"address_fingerprint": "secret", "view_key_fingerprint": "d" * 64},
        ):
            with patch.object(fixture, "docker", self.proof_docker([result])):
                with self.assertRaises((ValueError, subprocess.TimeoutExpired)):
                    self.run_retirement()
            self.assert_preserved()

    def test_receipt_binding_request_bounds_and_repeat_tampering(self):
        self.prepare()
        valid = json.dumps(self.request).encode()
        for raw in (
            b"x" * 16385,
            b"{}",
            valid.replace(b'"schema": 1', b'"schema": 1, "schema": 1'),
            valid.replace(b'"original_job": 12', b'"original_job": true'),
        ):
            with self.assertRaises(ValueError):
                retire.supersede(fixture, self.directory, self.baseline, self.job, raw)
        self.request["original_job"] = 99
        with self.assertRaises(ValueError):
            self.run_retirement()
        self.request["original_job"] = 12
        self.run_retirement()
        (self.directory / "wallet.tar").write_bytes(b"changed")
        with self.assertRaises(ValueError):
            self.run_retirement()

    def test_not_proven_receipt_and_import_proof_can_retire_without_becoming_verified(self):
        self.prepare()
        fixture.receipt(self.job, "NOT_PROVEN")
        state = fixture.load(self.directory, self.baseline)
        state["stage"] = "import_verified"
        fixture.write_state(self.directory, state)
        result = self.run_retirement()
        self.assertEqual(result["status"], "SUPERSEDED")
        self.assertEqual((self.job / "wallet-fixture-restore.state").read_bytes(), b"NOT_PROVEN\n")
        self.assertEqual(
            json.loads((self.directory / "state.json").read_bytes())["stage"], "import_verified"
        )

    def test_bad_save_and_graceful_stop_timeout_refuse_without_printing_logs(self):
        self.prepare()
        self.docker.item["State"]["ExitCode"] = 1
        with self.assertRaisesRegex(ValueError, "graceful save"):
            self.run_retirement()
        self.assert_preserved()
        self.docker.item["State"]["ExitCode"] = 0
        self.docker.dropped_terms = 10**6
        with (
            patch.object(fixture.time, "monotonic", side_effect=[0, 601]),
            patch("sys.stderr", io.StringIO()) as err,
        ):
            with self.assertRaisesRegex(ValueError, "no forced kill"):
                self.run_retirement()
        self.assertEqual(err.getvalue(), "")
        self.assert_preserved()

    def test_foreign_evidence_owner_refuses_before_any_wallet_operation(self):
        self.prepare()
        real_fstat = os.fstat

        def foreign(descriptor):
            info = real_fstat(descriptor)
            fields = list(info)
            fields[4] = info.st_uid + 1
            return os.stat_result(fields)

        with patch.object(retire.os, "fstat", side_effect=foreign):
            with self.assertRaisesRegex(ValueError, "owner-only"):
                self.run_retirement()
        self.assertFalse(self.docker.calls)
        self.assert_preserved()

    def test_tampered_retirement_records_never_echo_extra_or_missing_proof_fields(self):
        self.prepare()
        result = self.run_retirement()
        path = self.directory / "supersession.json"
        cases = []
        for field in (
            "method",
            "archived_keys_fingerprint",
            "live_keys_fingerprint",
            "encrypted_keys_match",
        ):
            changed = json.loads(json.dumps(result))
            del changed["proof"][field]
            cases.append(changed)
        cases.extend(
            [
                {**result, "private_value": "dummy-secret"},
                {**result, "proof": {**result["proof"], "address": "dummy-secret"}},
                {**result, "proof": {**result["proof"], "encrypted_keys_match": 1}},
                {**result, "proof": {**result["proof"], "live_keys_fingerprint": "f" * 64}},
            ]
        )
        for changed in cases:
            path.write_text(json.dumps(changed))
            with self.assertRaises(ValueError):
                self.run_retirement()
            script = HERE.parent / "lib/wallet_fixture_supersession.py"
            cli = subprocess.run(  # noqa: S603 -- fixed local CLI with synthetic input.
                [
                    sys.executable,
                    str(script),
                    str(self.baseline),
                    str(self.directory),
                    str(self.job),
                ],
                input=json.dumps(self.request).encode(),
                capture_output=True,
                check=False,
            )
            self.assertEqual(cli.returncode, 1)
            self.assertEqual(
                json.loads(cli.stdout), {"schema": 1, "status": "REFUSED", "identity_proven": False}
            )
            self.assertEqual(cli.stderr, b"")

    def test_capture_timeout_and_signal_cleanup_precede_live_restart(self):
        for failure in (subprocess.TimeoutExpired("docker", 180), InterruptedError("interrupted")):
            self.prepare()
            active = False
            events = []
            original = self.proof_docker([])

            def docker(*args, events=events, failure=failure, original=original, **kwargs):
                nonlocal active
                events.append(args)
                self.assertIsInstance(kwargs.get("timeout"), (int, float))
                self.assertGreater(kwargs["timeout"], 0)
                if args[0] == "run" and any("identity-capture" in value for value in args):
                    active = True
                    raise failure
                if args[0] == "ps" and "name=" in args[-1]:
                    return subprocess.CompletedProcess(args, 0, b"copy" if active else b"")
                if args[0] == "kill" and args[-1].endswith("identity-capture"):
                    return subprocess.CompletedProcess(args, 0, b"")
                if args[0] == "wait":
                    active = False
                    return subprocess.CompletedProcess(args, 0, b"0")
                if args[0] == "rm":
                    return subprocess.CompletedProcess(args, 0, b"")
                return original(*args, **kwargs)

            with patch.object(fixture, "docker", docker):
                with self.assertRaises(type(failure)):
                    self.run_retirement()
            self.assertLess(
                next(i for i, c in enumerate(events) if c[0] == "wait"),
                next(i for i, c in enumerate(events) if c[0] == "start"),
            )
            self.assertFalse(active)
            self.assert_preserved()
            self.job.rename(self.root / ("failed-" + type(failure).__name__))

    def test_signal_handlers_raise_through_cleanup_and_ignore_repeated_signals(self):
        with patch.object(retire.signal, "signal") as register:
            retire.install_signal_handlers()
            self.assertEqual(register.call_count, 3)
            handler = register.call_args_list[0].args[1]
            with self.assertRaises(InterruptedError):
                handler(retire.signal.SIGTERM, None)
            self.assertTrue(
                all(call.args[1] == retire.signal.SIG_IGN for call in register.call_args_list[-3:])
            )

    def test_cli_refusal_is_bounded_json_without_echoing_inputs(self):
        script = HERE.parent / "lib/wallet_fixture_supersession.py"
        result = subprocess.run(  # noqa: S603 -- fixed local test entry point.
            [sys.executable, str(script), "dummy", "dummy", "dummy"],
            input=b'{"password":"dummy-secret"}',
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            json.loads(result.stdout), {"schema": 1, "status": "REFUSED", "identity_proven": False}
        )
        self.assertEqual(result.stderr, b"")


if __name__ == "__main__":
    unittest.main()
