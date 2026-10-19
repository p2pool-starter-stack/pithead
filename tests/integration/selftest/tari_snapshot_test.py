import importlib.util
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "lib" / "tari-snapshot-state.py"
SPEC = importlib.util.spec_from_file_location("tari_snapshot", SOURCE)
snapshot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(snapshot)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.receipt = self.root / "tari-snapshot-restore.json"
        self.value = {"schema": 1, "job_id": 7, "commit": "a" * 40, "state": "ARMED"}
        self.write_receipt(self.value)
        snapshot.atomic(self.root / "state.json", {"mounts": []})

    def write_receipt(self, value):
        self.receipt.write_text(json.dumps(value))
        self.receipt.chmod(0o600)

    def test_receipt_transitions_preserve_identity_and_private_mode(self):
        self.assertEqual(snapshot.receipt(self.receipt, "7", "a" * 40), "ARMED")
        for state in ("NOT_PROVEN", "VERIFIED"):
            snapshot.receipt(self.receipt, "7", "a" * 40, state)
            self.assertEqual(json.loads(self.receipt.read_text()), {**self.value, "state": state})
            self.assertEqual(self.receipt.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(ValueError):
            snapshot.receipt(self.receipt, "7", "a" * 40, "NOT_PROVEN")

    def test_invalid_identity_and_shape_never_clear_fence(self):
        for change in (
            {"schema": True},
            {"job_id": True},
            {"job_id": 8},
            {"commit": "b" * 40},
            {"state": "UNKNOWN"},
            {"extra": True},
        ):
            with self.subTest(change=change):
                self.write_receipt({**self.value, **change})
                before = self.receipt.read_bytes()
                with self.assertRaises(ValueError):
                    snapshot.receipt(self.receipt, "7", "a" * 40, "VERIFIED")
                self.assertEqual(self.receipt.read_bytes(), before)

    def test_unsafe_receipt_is_rejected_without_blocking(self):
        self.receipt.chmod(0o644)
        with self.assertRaises(ValueError):
            snapshot.receipt(self.receipt, "7", "a" * 40, "VERIFIED")
        self.receipt.unlink()
        os.mkfifo(self.receipt, 0o600)
        with self.assertRaises(ValueError):
            snapshot.receipt(self.receipt, "7", "a" * 40, "VERIFIED")
        self.receipt.unlink()
        target = self.root / "target"
        target.write_text(json.dumps(self.value))
        target.chmod(0o600)
        self.receipt.symlink_to(target)
        with self.assertRaises(ValueError):
            snapshot.receipt(self.receipt, "7", "a" * 40, "VERIFIED")
        self.receipt.unlink()
        os.link(target, self.receipt)
        with self.assertRaises(ValueError):
            snapshot.receipt(self.receipt, "7", "a" * 40, "VERIFIED")

    def test_atomic_failure_keeps_previous_receipt(self):
        with patch.object(snapshot.os, "replace", side_effect=OSError("injected")):
            with self.assertRaises(OSError):
                snapshot.receipt(self.receipt, "7", "a" * 40, "VERIFIED")
        self.assertEqual(json.loads(self.receipt.read_text()), self.value)
        self.assertEqual(list(self.root.glob(".tari-state-*")), [])

    def test_wait_budget_is_shared_between_calls(self):
        snapshot.atomic(self.root / "migration.json", {"active": True, "sampled_at": time.time()})
        for bound in (0, 7200):
            with self.assertRaises(ValueError):
                snapshot.wait_clear(self.root, bound)

    def test_ready_probe_followed_by_wallet_failure_stays_active(self):
        data = {
            "mounts": [["tari-wallet", "/var/tari/wallet", str(self.root), "volume"]],
            "started_at": 1,
        }
        node = {"Id": "node", "State": {"Running": True, "StartedAt": "start", "Pid": 1}}
        with (
            patch.object(snapshot, "inspect", return_value=node),
            patch.object(snapshot, "opened"),
            patch.object(
                snapshot,
                "readiness",
                return_value={"ready": True, "migration": False, "phase": "READY"},
            ),
            patch.object(snapshot, "command", side_effect=OSError("log unavailable")),
        ):
            value = snapshot.sample(self.root, data)
        self.assertTrue(value["active"])
        self.assertTrue(value["observation_gap"])

    def test_migration_readiness_cannot_be_overridden_by_tip_health(self):
        data = {"mounts": [["tari", "/var/tari/node", str(self.root), "bind"]], "started_at": 1}
        node = {"Id": "node", "State": {"Running": True, "StartedAt": "start", "Pid": 1}}
        with (
            patch.object(snapshot, "inspect", return_value=node),
            patch.object(
                snapshot,
                "readiness",
                return_value={"ready": False, "migration": True, "phase": "migration"},
            ),
            patch.object(snapshot, "opened") as opened,
        ):
            value = snapshot.sample(self.root, data)
        opened.assert_not_called()
        self.assertTrue(value["active"])
        self.assertTrue(data["migration_observed"])

    def test_active_or_stale_migration_never_allows_stop(self):
        for value in (
            {"active": True, "sampled_at": time.time()},
            {"active": False, "sampled_at": 0},
        ):
            snapshot.atomic(self.root / "migration.json", value)
            with patch.object(snapshot, "inspect") as inspect:
                with self.assertRaises(ValueError):
                    snapshot.wait_clear(self.root, 0)
                inspect.assert_not_called()

    def test_ready_marker_is_bound_to_live_container_start(self):
        value = {
            "active": False,
            "sampled_at": time.time(),
            "container": "node",
            "started": "start",
        }
        snapshot.atomic(self.root / "migration.json", value)
        for container, started in (("different", "start"), ("node", "restart")):
            with patch.object(
                snapshot,
                "inspect",
                return_value={"Id": container, "State": {"Running": True, "StartedAt": started}},
            ):
                with self.assertRaises(ValueError):
                    snapshot.wait_clear(self.root, 0)
        with patch.object(
            snapshot,
            "inspect",
            return_value={"Id": "node", "State": {"Running": True, "StartedAt": "start"}},
        ):
            snapshot.wait_clear(self.root, 0)

    def test_missing_or_failed_probe_keeps_marker_active(self):
        data = {"mounts": [["tari", "/var/tari/node", str(self.root), "bind"]], "started_at": 1}
        with patch.object(snapshot, "inspect", side_effect=OSError("injected")):
            value = snapshot.sample(self.root, data)
        self.assertTrue(value["active"])
        self.assertTrue(value["observation_gap"])


class TargetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / "work"
        self.work.mkdir(mode=0o700)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake = Path(__file__).with_name("tari_snapshot_fakes.py")
        for name in ("sudo", "docker", "df", "sync"):
            target = self.bin / name
            shutil.copy2(fake, target)
            target.chmod(0o700)
        for name in ("live-state-support.sh", "tari-snapshot-state.py", "tari-snapshot-target.sh"):
            shutil.copy2(SOURCE.with_name(name), self.work / name)
            (self.work / name).chmod(0o600)
        snapshot.atomic(self.work / "identity.json", {"schema": 1, "job_id": 7, "commit": "a" * 40})
        self.env = {
            **os.environ,
            "SNAPSHOT_FIXTURE": str(self.root),
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
        }
        state = {}
        for service, directory, destination, kind in (
            ("tari", "node", "/var/tari/node", "bind"),
            ("tari-wallet", "wallet", "/var/tari/wallet", "volume"),
        ):
            source = self.root / directory
            source.mkdir()
            (source / "data.mdb").write_text(directory + " baseline data")
            state[service] = {
                "Id": service,
                "State": {"Running": True, "StartedAt": "baseline", "Pid": 1},
                "Mounts": [
                    {"Source": str(source), "Destination": destination, "Type": kind, "RW": True}
                ],
            }
        (self.root / "docker.json").write_text(json.dumps(state))

    def run_action(self, action, success=True):
        run = subprocess.run(  # noqa: S603
            ["bash", str(self.work / "tari-snapshot-target.sh"), str(self.work), action],  # noqa: S607
            env=self.env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if success:
            self.assertEqual(run.returncode, 0, run.stderr)
        else:
            self.assertNotEqual(run.returncode, 0)
        return run

    def ready(self):
        state = json.loads((self.root / "docker.json").read_text())
        for item in state.values():
            item["State"]["Running"] = True
        (self.root / "docker.json").write_text(json.dumps(state))
        snapshot.atomic(
            self.work / "migration.json",
            {
                "active": False,
                "sampled_at": time.time(),
                "container": "tari",
                "started": state["tari"]["State"]["StartedAt"],
                "wallet": "tari-wallet",
                "wallet_started": "baseline",
            },
        )

    def test_branch_marker_and_database_bytes_restore_before_baseline_open(self):
        self.run_action("capture")
        self.assertEqual((self.work / "stage").read_text().strip(), "captured")
        self.assertFalse(
            json.loads((self.root / "docker.json").read_text())["tari"]["State"]["Running"]
        )
        self.ready()
        self.run_action("branch")
        marker = json.loads((self.work / "state.json").read_text())["marker"]
        self.assertTrue((self.root / "node" / marker).exists())
        for name in ("node", "wallet"):
            (self.root / name / "data.mdb").write_text("candidate data")
        snapshot.atomic(self.work / "observer.done", {"stopped": True})
        self.run_action("restore")
        for name in ("node", "wallet"):
            self.assertEqual((self.root / name / "data.mdb").read_text(), name + " baseline data")
        self.assertFalse((self.root / "node" / marker).exists())
        self.assertFalse(
            json.loads((self.root / "docker.json").read_text())["tari"]["State"]["Running"]
        )
        self.ready()
        self.run_action("verify")
        self.assertTrue(list((self.work / "snapshots").iterdir()))
        self.run_action("cleanup")
        self.assertEqual(list((self.work / "snapshots").iterdir()), [])

    def test_non_cow_refusal_stops_no_writer(self):
        self.env["REFLINK_FAIL"] = "1"
        self.run_action("capture", success=False)
        self.assertNotIn("docker stop", (self.root / "commands").read_text())
        self.assertEqual((self.root / "node" / "data.mdb").read_text(), "node baseline data")

    def test_space_refusal_stops_no_writer(self):
        self.env["FIXTURE_FREE"] = "1"
        self.run_action("capture", success=False)
        self.assertNotIn("docker stop", (self.root / "commands").read_text())

    def test_interrupted_stops_and_swaps_retain_durable_recovery_journal(self):
        for sig in ("SIGTERM", "SIGKILL"):
            for tool, count, before in (
                ("docker", 1, False),
                ("mv", 1, True),
                ("mv", 1, False),
                ("mv", 2, False),
                ("mv", 4, False),
            ):
                with self.subTest(signal=sig, tool=tool, count=count, before=before):
                    self.setUp()
                    self.run_action("capture")
                    self.ready()
                    snapshot.atomic(self.work / "observer.done", {"stopped": True})
                    self.env.update(
                        INTERRUPT_TOOL=tool, INTERRUPT_COUNT=str(count), INTERRUPT_SIGNAL=sig
                    )
                    if before:
                        self.env["INTERRUPT_BEFORE"] = "1"
                    self.run_action("restore", success=False)
                    self.assertTrue(list((self.work / "snapshots").iterdir()))
                    journal = (self.work / "journal.sh").read_text()
                    self.assertIn("UPGRADE_STATE_SNAPSHOTS", journal)
                    if tool == "mv":
                        self.assertIn("pithead-old-", journal)
                    self.assertNotEqual((self.work / "stage").read_text().strip(), "verified")

    def test_cleanup_failure_keeps_durable_proof_and_pending_stage(self):
        self.run_action("capture")
        self.ready()
        snapshot.atomic(self.work / "observer.done", {"stopped": True})
        self.run_action("restore")
        self.ready()
        self.run_action("verify")
        self.env["RM_FAIL"] = "1"
        self.run_action("cleanup", success=False)
        self.assertTrue((self.work / "proof.json").exists())
        self.assertEqual((self.work / "stage").read_text().strip(), "proven")
        self.assertTrue(list((self.work / "snapshots").iterdir()))

    def test_term_and_kill_leave_active_migration_snapshots_untouched(self):
        self.run_action("capture")
        snapshot.atomic(self.work / "migration.json", {"active": True, "sampled_at": time.time()})
        for sig in (signal.SIGTERM, signal.SIGKILL):
            before = (self.root / "commands").read_text()
            process = subprocess.Popen(  # noqa: S603
                ["bash", str(self.work / "tari-snapshot-target.sh"), str(self.work), "restore"],  # noqa: S607
                env=self.env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            try:
                time.sleep(0.2)
                os.killpg(process.pid, sig)
                process.wait(timeout=5)
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)
            self.assertEqual((self.root / "commands").read_text(), before)
            self.assertTrue(list((self.work / "snapshots").iterdir()))
            self.assertEqual((self.work / "stage").read_text().strip(), "captured")

    def test_logs_are_not_read_as_migration_completion(self):
        data = {"mounts": [["tari", "/var/tari/node", str(self.root), "bind"]], "started_at": 1}
        node = {"Id": "node", "State": {"Running": True, "StartedAt": "start", "Pid": 1}}
        with (
            patch.object(snapshot, "inspect", return_value=node),
            patch.object(snapshot, "opened", side_effect=subprocess.TimeoutExpired("probe", 1)),
        ):
            value = snapshot.sample(self.root, data)
        self.assertTrue(value["active"])


if __name__ == "__main__":
    unittest.main()
