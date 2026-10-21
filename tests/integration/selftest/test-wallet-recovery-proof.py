"""The lifecycle recovery proof: its plumbing, assertions and fixed failure labels, without a bench."""

import importlib.util
import json
import os
import shutil
import stat
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


base = module("recovery_tests", HERE / "test-wallet-recovery.py")
fixture, retire, recovery, existing = base.fixture, base.retire, base.recovery, base.existing
proof = module("proof", HERE.parent / "tools/prove-wallet-recovery.py")
COMMIT = "a" * 40
LEAK = "private-address-and-view-key"


class ProofBase(base.RecoveryBase):
    def setUp(self):
        super().setUp()
        self.live.volume = True
        self.runs = []
        self.after = None
        self.outcome = None
        modules = {"wallet-fixture.py": fixture, "wallet_fixture_recovery.py": recovery}
        lib = {"wallet-fixture.py": fixture, "wallet_fixture_supersession.py": retire}
        env = {"RIG_LOCK_FILE": str(self.root / "rig.lock")}
        for patcher in (
            patch.object(proof, "load", lambda name, path: modules[Path(path).name]),
            patch.object(proof.supersession, "wait_prepared"),
            patch.object(proof.subprocess, "check_output", return_value=COMMIT),
            patch.object(proof, "run_recovery", self.run_recovery),
            patch.object(recovery, "load_module", lambda name, filename: lib[filename]),
            patch.dict(os.environ, env),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)

    def run_recovery(self, baseline, snapshot, job, raw, scratch, timeout, log):
        self.runs.append(
            {"baseline": baseline, "snapshot": snapshot, "job": job, "raw": raw, "timeout": timeout}
        )
        log.write_text("recovery stderr\n")
        if self.outcome and len(self.runs) in self.outcome:
            return self.outcome[len(self.runs)]
        code, text = recovery.run([str(baseline), str(snapshot), str(job)], raw, self.steps)
        if len(self.runs) == 1 and self.after:
            self.after(snapshot, job)
        return code, text.encode()

    def result(self):
        os.environ["IT_SCRATCH_DIR"] = str(self.root)  # the proof re-points it at its own scratch
        self.runs.clear()
        code, result = proof.run_proof(self.baseline)
        self.assertEqual(code, 1)
        self.assertNotIn(LEAK, json.dumps(result))
        self.assertNotIn(str(self.baseline), json.dumps(result))
        return result


class SuccessTest(ProofBase):
    def test_a_real_recovery_is_run_through_the_operator_entry_point_and_every_outcome_is_asserted(
        self,
    ):
        stages = []
        context = {}
        result = proof.prove(self.baseline, stages.append, context)
        self.assertEqual(
            result,
            {
                "schema": 1,
                "restore_proven": True,
                "method": "encrypted_keys",
                "live_identity_proven": True,
                "import_verified": True,
                "wallet_ready": True,
                "receipt_verified": True,
                "ready_fence_proven": True,
                "cleanup_proven": True,
                "replay_refused": True,
            },
        )
        self.assertEqual(
            stages,
            [
                "configured_identity",
                "scratch",
                "prepared_capture",
                "capture",
                "original_receipt",
                "receipt_fence",
                "commit_reference",
                "snapshot_state",
                "prepared_recovery",
                "recover",
                "verdict",
                "receipt",
                "cleanup",
                "replay_refusal",
            ],
        )
        first, replay = self.runs
        self.assertEqual(first["timeout"], proof.RECOVERY_TIMEOUT)
        self.assertEqual(replay["timeout"], proof.REPLAY_TIMEOUT)
        self.assertEqual(
            json.loads(first["raw"]),
            {
                "schema": 1,
                "original_job": 1,
                "original_commit": COMMIT,
                "recovery_issues": ["pithead#3483"],
            },
        )
        self.assertEqual(replay["raw"], first["raw"])
        self.assertEqual(first["baseline"], self.baseline)
        self.assertEqual(first["job"].name, "1")
        self.assertTrue(first["snapshot"].name.startswith("pithead-wallet-fixture-"))
        self.assertEqual(
            (first["job"] / "wallet-fixture-restore.state").read_bytes(), b"VERIFIED\n"
        )
        self.assertEqual({p.name for p in first["snapshot"].iterdir()}, {"state.json"})
        self.assertEqual(Path(context["log"]).read_text(), "recovery stderr\n")
        self.assertEqual(self.steps.calls[:4], ["lock", "start", "ready", "lock"])
        self.assertEqual(self.docker.contents, existing.archive())
        self.assertNotIn(str(self.root), json.dumps(result))

    def test_the_snapshot_is_the_proofs_own_and_the_scratch_is_private(self):
        context = {}
        proof.prove(self.baseline, lambda stage: None, context)
        scratch = Path(context["log"]).parent
        self.assertEqual(scratch.parent, self.root)
        self.assertEqual(stat.S_IMODE(scratch.stat().st_mode), 0o700)
        self.assertTrue((scratch / "1").is_dir())
        self.assertEqual(self.runs[0]["snapshot"].parent, scratch)

    def test_run_proof_prints_fixed_stage_labels_to_stderr_only(self):
        with patch("sys.stderr") as stderr:
            code, result = proof.run_proof(self.baseline)
        self.assertEqual((code, result["restore_proven"]), (0, True))
        written = "".join(call.args[0] for call in stderr.write.call_args_list)
        self.assertIn("wallet recovery proof: recover", written)
        self.assertNotIn(str(self.root), written)


class FailureTest(ProofBase):
    def test_every_stage_failure_names_a_fixed_stage_and_never_echoes_values(self):
        with patch.object(fixture, "capture", side_effect=ValueError(LEAK)):
            result = self.result()
        self.assertEqual(
            {k: v for k, v in result.items() if k != "log"},
            {
                "schema": 1,
                "restore_proven": False,
                "failed_stage": "capture",
                "failure_reason": "validation_refused",
            },
        )
        self.assertEqual(Path(result["log"]).name, "recovery.log")
        with patch.object(fixture, "identity", side_effect=ValueError(LEAK)):
            result = self.result()
        self.assertEqual(result["failed_stage"], "configured_identity")
        self.assertNotIn("log", result)

    def test_an_unprepared_wallet_fails_before_any_scratch_exists(self):
        self.env.write_text(self.env.read_text().replace("MONERO_VIEW_KEY=dummy-view-key", ""))
        result = self.result()
        self.assertEqual(result["failed_stage"], "configured_identity")
        self.assertFalse(list(self.root.glob("pithead-wallet-recovery-proof-*")))

    def test_known_guards_and_command_failures_map_to_fixed_reasons(self):
        for error, label in (
            (ValueError("wallet volume has another consumer"), "extra_consumer"),
            (subprocess.CalledProcessError(1, [LEAK]), "command_failed"),
            (subprocess.TimeoutExpired([LEAK], 30), "command_timeout"),
            (OSError(LEAK), "evidence_unavailable"),
            (InterruptedError(LEAK), "interrupted"),
        ):
            with self.subTest(label=label), patch.object(fixture, "capture", side_effect=error):
                self.assertEqual(self.result()["failure_reason"], label)

    def test_a_refusal_is_labelled_with_its_closed_reason_only(self):
        for text, reason in (
            (b'{"schema": 1, "status": "REFUSED", "reason": "readiness"}', "readiness"),
            (b'{"schema": 1, "status": "REFUSED", "reason": "busy"}', "busy"),
            (b'{"schema": 1, "status": "REFUSED", "reason": "' + LEAK.encode() + b'"}', "unknown"),
            (b'{"reason": ["x"]}', "unknown"),
            (b"not json " + LEAK.encode(), "unknown"),
            (b"", "unknown"),
        ):
            with self.subTest(reason=reason):
                self.outcome = {1: (1, text)}
                result = self.result()
                self.assertEqual(result["failed_stage"], "recover")
                self.assertEqual(result["failure_reason"], "recovery_refused")
                self.assertEqual(result["recovery_reason"], reason)

    def test_a_refused_recovery_leaves_the_snapshot_and_receipt_for_an_exact_retry(self):
        self.steps.fail["ready"] = subprocess.CalledProcessError(1, "ready")
        result = self.result()
        self.assertEqual(result["recovery_reason"], "readiness")
        job = self.runs[0]["job"]
        snapshot = self.runs[0]["snapshot"]
        self.assertEqual((job / "wallet-fixture-restore.state").read_bytes(), b"ARMED\n")
        self.assertEqual(
            json.loads((snapshot / "state.json").read_text())["stage"], "import_verified"
        )
        self.assertTrue((snapshot / "wallet.tar").exists())
        self.assertEqual(Path(result["log"]).read_text(), "recovery stderr\n")

    def test_the_receipt_must_not_reach_verified_without_ready(self):
        real = fixture.receipt
        with patch.object(
            fixture, "receipt", lambda job, stage: real(job, stage) if stage == "ARMED" else None
        ):
            result = self.result()
        self.assertEqual(result["failed_stage"], "receipt_fence")
        self.assertEqual(result["failure_reason"], "receipt_fence_open")
        self.assertFalse(self.runs)

    def test_a_recovery_that_compared_no_live_wallet_does_not_prove_the_identity_gate(self):
        self.live.volume = False
        result = self.result()
        self.assertEqual(result["failed_stage"], "verdict")
        self.assertEqual(result["failure_reason"], "live_identity_unproven")

    def test_a_verdict_that_is_malformed_or_not_ours_fails_the_verdict_stage(self):
        def bad(change):
            def run(baseline, snapshot, job, raw, scratch, timeout, log):
                code, text = recovery.run([str(baseline), str(snapshot), str(job)], raw, self.steps)
                verdict = json.loads(text)
                change(verdict)
                return code, json.dumps(verdict).encode()

            return run

        cases = (
            (lambda v: v.update(status="REFUSED"), "verdict_invalid"),
            (lambda v: v["proof"].update(address="dummy-address"), "verdict_invalid"),
            (lambda v: v["proof"].update(wallet_ready=False), "verdict_invalid"),
            (lambda v: v["request"].update(original_commit="b" * 40), "verdict_mismatch"),
            (lambda v: v["proof"].update(archive_fingerprint="c" * 64), "verdict_mismatch"),
            (lambda v: v["proof"].update(keys_fingerprint="d" * 64), "verdict_mismatch"),
        )
        for change, reason in cases:
            with self.subTest(reason=reason):
                with patch.object(proof, "run_recovery", bad(change)):
                    result = self.result()
                self.assertEqual(
                    (result["failed_stage"], result["failure_reason"]), ("verdict", reason)
                )
                self.job_cleanup()
        self.outcome = {1: (0, b"[]")}
        self.assertEqual(self.result()["failure_reason"], "verdict_invalid")

    def job_cleanup(self):
        for scratch in self.root.glob("pithead-wallet-recovery-proof-*"):
            shutil.rmtree(scratch)
        self.docker.contents = existing.archive()

    def test_a_receipt_that_is_not_verified_fails_the_receipt_stage(self):
        self.after = lambda snapshot, job: (job / "wallet-fixture-restore.state").write_bytes(
            b"READY\n"
        )
        result = self.result()
        self.assertEqual(
            (result["failed_stage"], result["failure_reason"]), ("receipt", "receipt_not_verified")
        )

    def test_leftover_fixture_files_helpers_or_proof_directories_fail_the_cleanup_stage(self):
        leftovers = (
            lambda snapshot, job: (snapshot / "wallet.tar").write_bytes(b"left behind"),
            lambda snapshot, job: (job / "extra").write_bytes(b"left behind"),
            lambda snapshot, job: (snapshot.parent / "pithead-wallet-proof-x").mkdir(),
            lambda snapshot, job: setattr(self.live, "helpers", b"0123456789ab\n"),
        )
        for leftover in leftovers:
            with self.subTest(leftover=leftover):
                self.after = leftover
                self.live.helpers = b""
                result = self.result()
                self.assertEqual(
                    (result["failed_stage"], result["failure_reason"]),
                    ("cleanup", "cleanup_incomplete"),
                )
                self.job_cleanup()

    def test_a_replay_that_is_not_refused_at_the_receipt_fails_the_replay_stage(self):
        for second in (
            (0, b"{}"),
            (1, b'{"schema": 1, "status": "REFUSED", "reason": "readiness"}'),
            (1, b""),
        ):
            with self.subTest(second=second):
                self.outcome = {2: second}
                result = self.result()
                self.assertEqual(
                    (result["failed_stage"], result["failure_reason"]),
                    ("replay_refusal", "replay_not_refused"),
                )
                self.job_cleanup()


if __name__ == "__main__":
    unittest.main()
