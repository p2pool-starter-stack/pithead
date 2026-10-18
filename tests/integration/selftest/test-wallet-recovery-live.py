"""The live wallet proof and its boundaries: what may be overwritten, and when it is proved."""

import copy
import importlib.util
import subprocess
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


base = module("recovery_tests", HERE / "test-wallet-recovery.py")
existing = base.existing


class LiveWalletTest(base.RecoveryBase):
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

    def test_a_live_wallet_in_the_e2e_checkout_is_proved_and_a_third_checkout_is_refused(self):
        def checkout(path):
            self.docker.item["Config"]["Labels"]["com.docker.compose.project.working_dir"] = str(
                path
            )

        self.prepare()
        self.live.volume = True
        self.docker.contents = existing.archive({"payout-wallet": b"newer cache"})
        checkout(self.root / "branch")
        self.assertEqual(self.recover()["proof"]["method"], "encrypted_keys")
        self.assertEqual(self.docker.contents, self.original)
        checkout(self.baseline)
        self.prepare()
        self.steps.calls.clear()
        self.live.volume = True
        checkout(self.root / "elsewhere")
        self.refused("identity")
        self.assert_untouched()
        self.assertEqual(self.steps.calls, ["lock"])

    def test_a_retry_after_the_import_began_needs_no_live_wallet_proof(self):
        pristine = copy.deepcopy(self.docker.item)

        def removed():
            self.docker.item = None

        def exited():
            self.docker.item["State"].update(Running=False, ExitCode=143)

        def fail_start():
            self.steps.fail["start"] = subprocess.CalledProcessError(1, "start")
            return "startup"

        def fail_gate():
            self.steps.fail["ready"] = subprocess.CalledProcessError(1, "ready")
            return "readiness"

        def interrupt_import():
            self.live.import_error = InterruptedError("signal")
            return "interrupted"

        for failure in (fail_start, fail_gate, interrupt_import):
            for strand in (removed, exited):
                with self.subTest(failure=failure.__name__, consumer=strand.__name__):
                    self.docker.item = copy.deepcopy(pristine)
                    self.prepare()
                    self.refused(failure())
                    self.assertEqual(self.receipt(), b"ARMED\n")
                    self.steps.fail.clear()
                    self.live.import_error = None
                    self.live.volume = True
                    strand()
                    self.docker.calls.clear()
                    verdict = self.recover()
                    self.assertEqual(verdict["proof"]["method"], "resumed")
                    self.assertFalse(verdict["proof"]["live_identity_proven"])
                    self.assertEqual(self.receipt(), b"VERIFIED\n")
                    self.assertEqual(self.docker.contents, self.original)
                    self.assertFalse([c for c in self.docker.calls if c[:2] == ("volume", "ls")])
                    self.live.volume = False


if __name__ == "__main__":
    unittest.main()
