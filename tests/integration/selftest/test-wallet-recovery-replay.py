import importlib.util
import json
import os
import shutil
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("base", HERE / "test-wallet-recovery.py")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
fixture, recovery = base.fixture, base.recovery
records = recovery.records


class ReplayTest(base.RecoveryBase):
    def test_final_receipt_interrupt_replays_original_proof_without_touching_wallet(self):
        self.prepare()
        real = fixture.receipt

        def lost(directory, stage):
            real(directory, stage)
            if stage == "VERIFIED":
                raise InterruptedError

        with patch.object(fixture, "receipt", lost):
            self.refused("interrupted")
        self.assertEqual(self.receipt(), b"VERIFIED\n")
        self.assertTrue((self.job / records.NAME).is_file(), "final seal lost durable proof")
        expected = json.loads((self.job / records.NAME).read_text())["verdict"]
        self.docker.contents = b"a later wallet must never be overwritten"
        self.docker.calls.clear()
        self.steps.calls.clear()
        self.assertEqual(self.recover(), expected)
        self.assertEqual(self.docker.calls, [])
        self.assertEqual(self.steps.calls, ["lock"])
        self.assertEqual(self.docker.contents, b"a later wallet must never be overwritten")
        self.assertEqual((self.job / records.NAME).stat().st_mode & 0o777, 0o600)

    def test_sealing_boundaries_resume_without_reimport_or_repeated_gate(self):
        for boundary in ("published", "ready", "cleanup", "partial_cleanup"):
            with self.subTest(boundary=boundary):
                self.prepare()
                publish, receipt, cleanup = records.publish, fixture.receipt, fixture.cleanup

                def publish_interrupt(*args, publish=publish):
                    publish(*args)
                    raise InterruptedError

                def receipt_interrupt(directory, stage, receipt=receipt):
                    receipt(directory, stage)
                    if stage == "READY":
                        raise InterruptedError

                def cleanup_interrupt(directory, baseline, boundary=boundary, cleanup=cleanup):
                    if boundary == "partial_cleanup":
                        state = fixture.load(directory, baseline, cleanup_only=True)
                        state["stage"] = "ready"
                        fixture.write_state(directory, state)
                        (directory / "wallet.tar").unlink()
                    else:
                        cleanup(directory, baseline)
                    raise InterruptedError

                target, name, callback = {
                    "published": (records, "publish", publish_interrupt),
                    "ready": (fixture, "receipt", receipt_interrupt),
                    "cleanup": (fixture, "cleanup", cleanup_interrupt),
                    "partial_cleanup": (fixture, "cleanup", cleanup_interrupt),
                }[boundary]
                with patch.object(target, name, callback):
                    self.refused("interrupted")
                self.docker.calls.clear()
                self.steps.calls.clear()
                self.assertEqual(self.recover()["status"], "RESTORED")
                self.assertEqual(self.receipt(), b"VERIFIED\n")
                self.assertEqual(self.imports(), [])
                self.assertEqual(self.steps.calls, ["lock"])
                self.assertEqual({p.name for p in self.directory.iterdir()}, {"state.json"})

    def test_failed_publication_preserves_archives_and_receipt(self):
        self.prepare()
        real = Path.replace

        def failed(path, target):
            if Path(target).name == records.NAME:
                raise OSError
            return real(path, target)

        with patch.object(records.Path, "replace", failed):
            self.refused("seal")
        self.assertEqual(self.receipt(), b"ARMED\n")
        self.assertTrue((self.directory / "wallet.tar").exists())
        self.assertTrue((self.directory / "image.tar").exists())
        self.assertFalse((self.job / records.NAME).exists())
        self.assertFalse(list(self.job.glob(".wallet-recovery-*")))

    def test_interrupted_publication_directory_sync_is_completed_on_retry(self):
        self.prepare()
        sync = fixture.sync_directory

        def interrupted(directory):
            if directory == self.job and (directory / records.NAME).exists():
                raise InterruptedError
            sync(directory)

        with patch.object(fixture, "sync_directory", interrupted):
            self.refused("interrupted")
        self.assertEqual(self.receipt(), b"ARMED\n")
        self.assertTrue((self.directory / "wallet.tar").exists())
        self.docker.calls.clear()
        self.steps.calls.clear()
        self.request["recovery_issues"] = ["pithead#1"]
        self.refused("verdict")
        self.assertEqual(self.receipt(), b"ARMED\n")
        self.assertTrue((self.directory / "wallet.tar").exists())
        self.request["recovery_issues"] = ["bench-ci#2019", "pithead#3483"]
        with patch.object(fixture, "sync_directory", wraps=sync) as synced:
            self.assertEqual(self.recover()["status"], "RESTORED")
        self.assertEqual(synced.call_args_list[0].args, (self.job,))
        self.assertEqual(self.docker.calls, [])
        self.assertEqual(self.steps.calls, ["lock"])

    def test_wrong_request_snapshot_and_damaged_proof_refuse_without_mutation(self):
        self.prepare()
        verdict = self.recover()
        target = self.job / records.NAME
        original = target.read_bytes()
        for field, value in (("original_commit", "b" * 40), ("recovery_issues", ["pithead#1"])):
            self.request[field], saved = value, self.request[field]
            self.refused("verdict")
            self.request[field] = saved
        mutations = [
            lambda r: r.update(schema=True),
            lambda r: r.update(extra=True),
            lambda r: r.update(snapshot="elsewhere"),
            lambda r: r.update(state_fingerprint="0" * 64),
            lambda r: r["verdict"]["proof"].update(wallet_ready=False),
            lambda r: r["verdict"]["proof"].update(keys_fingerprint="0" * 64),
            lambda r: r["verdict"].update(schema=True),
        ]
        self.docker.calls.clear()
        self.steps.calls.clear()
        for mutate in mutations:
            record = json.loads(original)
            mutate(record)
            target.write_text(json.dumps(record))
            self.refused("verdict")
        for raw in (b"{}", b"[]", b"null", b"bad", original[:-1] + b', "schema": 1}'):
            target.write_bytes(raw)
            self.refused("verdict")
        target.write_bytes(original)
        target.chmod(0o644)
        self.refused("verdict")
        target.chmod(0o600)
        target.unlink()
        target.symlink_to(self.job / "absent")
        self.refused("verdict")
        target.unlink()
        self.refused("receipt")
        self.assertEqual(self.receipt(), b"VERIFIED\n")
        self.assertEqual(self.docker.calls, [])
        self.assertEqual(self.steps.calls, [])
        target.write_bytes(original)
        target.chmod(0o600)
        self.assertEqual(self.recover(), verdict)
        other = self.directory.with_name(self.directory.name + "-copy")
        shutil.copytree(self.directory, other)
        self.directory = other
        self.refused("archive")

    def test_response_serialization_loss_has_a_supported_exact_retry(self):
        self.prepare()
        modules = {"wallet-fixture.py": fixture, "wallet_fixture_supersession.py": base.retire}
        argv = [str(self.baseline), str(self.directory), str(self.job)]
        raw = json.dumps(self.request).encode()
        dumps = json.dumps

        def lost(value, **kwargs):
            if isinstance(value, dict) and value.get("status") == "RESTORED":
                raise InterruptedError
            return dumps(value, **kwargs)

        with (
            patch.object(recovery, "load_module", lambda name, filename: modules[filename]),
            patch.dict(os.environ, {"RIG_LOCK_FILE": str(self.root / "rig.lock")}),
        ):
            with patch.object(recovery.json, "dumps", lost), self.assertRaises(InterruptedError):
                recovery.run(argv, raw, self.steps)
            self.assertEqual(self.receipt(), b"VERIFIED\n")
            self.assertEqual(recovery.run(argv, raw, self.steps)[0], 0)


if __name__ == "__main__":
    unittest.main()
