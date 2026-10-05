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
            fixture.capture.side_effect = lambda baseline: print(snapshot)
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
                        patch.object(proof, "load", side_effect=[fixture, retirement]),
                        patch.dict(proof.os.environ, {"IT_SCRATCH_DIR": scratch}),
                        patch.object(proof.subprocess, "check_output", return_value="a" * 40),
                    ):
                        code, result = proof.run_proof(root)
                    self.assertEqual(code, 1)
                    self.assertEqual(
                        result, {"schema": 1, "identity_proven": False, "failed_stage": stage}
                    )
                    self.assertNotIn("private", json.dumps(result))
                    target.side_effect = original

    def test_success_preserves_existing_machine_proof(self):
        expected = {"schema": 1, "identity_proven": True, "isolated_open_proven": True}
        with patch.object(proof, "prove", return_value=expected):
            self.assertEqual(proof.run_proof(Path(".")), (0, expected))


if __name__ == "__main__":
    unittest.main()
