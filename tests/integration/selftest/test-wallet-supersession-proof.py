"""Lifecycle refusals identify a bounded stage without disclosing wallet values."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "proof", HERE.parent / "tools/prove-wallet-supersession.py"
)
proof = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proof)


class ProofDiagnosticsTest(unittest.TestCase):
    def test_real_stage_refusals_never_echo_exception_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot = root / "snapshot"
            snapshot.mkdir()
            (snapshot / "wallet.tar").write_bytes(b"private-wallet-data")
            fixture = Mock()
            retirement = Mock()
            fixture.capture.side_effect = lambda baseline, **kwargs: print(snapshot)
            fixture.load.return_value = {"image": "private-image"}
            retirement.open_copy.return_value = {"identity": True}
            for stage, target in (
                ("configured_identity", fixture.identity),
                ("capture", fixture.capture),
                ("validate_snapshot", fixture.load),
                ("isolated_open_archive", retirement.open_copy),
                ("supersede_live", retirement.supersede),
            ):
                with self.subTest(stage=stage), tempfile.TemporaryDirectory(dir=root) as scratch:
                    original = target.side_effect
                    target.side_effect = ValueError("private-address-and-view-key")
                    with (
                        patch.object(proof, "wait_prepared"),
                        patch.object(proof, "load", side_effect=[fixture, retirement]),
                        patch.dict(proof.os.environ, {"IT_SCRATCH_DIR": scratch}),
                        patch.object(proof.subprocess, "check_output", return_value="a" * 40),
                    ):
                        code, result = proof.run_proof(root)
                    self.assertEqual(code, 1)
                    self.assertEqual(
                        result,
                        {
                            "schema": 1,
                            "identity_proven": False,
                            "failed_stage": stage,
                            "failure_reason": "validation_refused",
                        },
                    )
                    self.assertNotIn("private", json.dumps(result))
                    target.side_effect = original

    def test_prepared_marker_must_clear_without_stopping_wallet(self):
        fixture = Mock(WALLET_DIR="/wallets")
        fixture.wallet_container.return_value = {"Id": "wallet", "State": {"Running": True}}
        fixture.docker.side_effect = [Mock(returncode=1), Mock(returncode=0)]
        with patch.object(proof.time, "sleep") as sleep:
            proof.wait_prepared(fixture, Path("baseline"))
        fixture.wallet_container.assert_called_once_with({Path("baseline")}, timeout=30)
        self.assertEqual(fixture.docker.call_count, 2)
        self.assertEqual(sleep.call_count, 1)
        for call in fixture.docker.call_args_list:
            self.assertEqual(
                call.args, ("exec", "wallet", "test", "!", "-e", "/wallets/.payout-scanning")
            )
            self.assertFalse(call.kwargs["check"])
            self.assertLessEqual(call.kwargs["timeout"], 30)

    def test_marker_deadline_and_missing_wallet_refuse(self):
        fixture = Mock()
        fixture.wallet_container.return_value = {"Id": "wallet", "State": {"Running": True}}
        with patch.object(proof.time, "monotonic", side_effect=[0, 1200]):
            with self.assertRaisesRegex(ValueError, "deadline exceeded"):
                proof.wait_prepared(fixture, Path("baseline"))
        fixture.docker.assert_not_called()
        for item in (None, {"State": {"Running": False}}):
            fixture.wallet_container.return_value = item
            with self.assertRaisesRegex(ValueError, "not running"):
                proof.wait_prepared(fixture, Path("baseline"))

    def test_failure_reasons_are_fixed_and_never_echo_values(self):
        for error, label in (
            (ValueError("wallet consumer belongs to another checkout"), "checkout_owner"),
            (ValueError("private-wallet-key"), "validation_refused"),
            (OSError("private-path"), "evidence_unavailable"),
            (proof.subprocess.CalledProcessError(1, ["private-command"]), "command_failed"),
            (proof.subprocess.TimeoutExpired(["private-command"], 30), "command_timeout"),
        ):
            self.assertEqual(proof.failure_reason(error), label)

    def test_success_waits_before_capture_and_live_supersession(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot = root / "snapshot"
            snapshot.mkdir()
            (snapshot / "wallet.tar").write_bytes(b"private-fixture")
            fixture, retirement = Mock(), Mock()
            fixture.capture.side_effect = lambda baseline, **kwargs: print(snapshot)
            fixture.receipt.side_effect = lambda job, stage: (
                job / "wallet-fixture-restore.state"
            ).write_bytes(b"ARMED\n")
            fixture.digest.return_value = "digest"
            fixture.load.return_value = {"image": "private-image"}
            fixture.restore.side_effect = ValueError("replay refused")
            retirement.open_copy.return_value = {"identity": True}
            retirement.supersede.return_value = {
                "proof": {"encrypted_keys_match": True, "identity_proven": True}
            }
            stages = []
            with (
                patch.object(proof, "load", side_effect=[fixture, retirement]),
                patch.dict(proof.os.environ, {"IT_SCRATCH_DIR": directory}),
                patch.object(proof.subprocess, "check_output", return_value="a" * 40),
                patch.object(
                    proof, "wait_prepared", side_effect=lambda *args: stages.append("wait")
                ),
            ):
                result = proof.prove(root, stages.append)
            self.assertEqual(
                result,
                {
                    "schema": 1,
                    "identity_proven": True,
                    "isolated_open_proven": True,
                    "evidence_preserved": True,
                    "idempotence_proven": True,
                    "replay_refused": True,
                },
            )
            for stage in ("prepared_capture", "prepared_supersession"):
                self.assertEqual(stages[stages.index(stage) + 1], "wait")
            self.assertEqual(stages.count("wait"), 2)
            self.assertEqual(retirement.supersede.call_count, 2)
            fixture.capture.assert_called_once_with(root, diagnostics=False)


if __name__ == "__main__":
    unittest.main()
