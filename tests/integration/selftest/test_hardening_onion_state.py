import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "lib/hardening_onion_state.py"
spec = importlib.util.spec_from_file_location("onion_state", SOURCE)
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class OnionStateTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.cwd = Path.cwd()
        self.root = Path(self.work.name).resolve()
        os.chdir(self.root)
        self.tor = self.root / "tor"
        self.tor.mkdir()
        self.env = self.root / ".env"
        self.original = b"DASHBOARD_ONION_ADDRESS=placeholder\nOPAQUE_STATE=baseline\n"
        self.env.write_bytes(self.original)
        self.env.chmod(0o600)
        (self.root / "config.json").write_text("{}\n")
        self.mounts = []
        self.commands = []
        self.mock = patch.object(state.subprocess, "run", side_effect=self.docker)
        self.mocked = self.mock.start()

    def tearDown(self):
        self.mock.stop()
        os.chdir(self.cwd)
        self.work.cleanup()

    def docker(self, args, **_kwargs):
        self.commands.append(args)
        if args[1] == "ps":
            return SimpleNamespace(stdout="synthetic\n")
        if args[1] == "inspect":
            return SimpleNamespace(stdout=json.dumps([{"Mounts": self.mounts}]))
        return SimpleNamespace(stdout="")

    def save(self):
        with redirect_stdout(io.StringIO()) as output:
            state.save(str(self.tor))
        return Path(output.getvalue().strip())

    def mutate(self):
        self.env.write_text("synthetic generated state\n")
        target = self.tor / "dashboard"
        target.mkdir(exist_ok=True)
        (target / "key").write_text("generated identity\n")

    def restore(self, snapshot):
        metadata, target = state.load(snapshot)
        state.restore(snapshot, metadata, target)
        state.verify(snapshot, metadata, target)

    def test_absent_identity_and_entire_env_restore_idempotently(self):
        snapshot = self.save()
        self.mutate()
        self.restore(snapshot)
        self.restore(snapshot)
        self.assertEqual(self.env.read_bytes(), self.original)
        self.assertFalse((self.tor / "dashboard").exists())
        self.assertTrue((snapshot / "quarantine/key").is_file())
        self.assertEqual((snapshot / "env").read_bytes(), self.original)
        with patch.object(state.sys, "argv", ["state", "cleanup", str(snapshot)]):
            state.main()
        self.assertFalse(snapshot.exists())

    def test_historical_disabled_identity_is_restored_with_metadata(self):
        target = self.tor / "dashboard"
        target.mkdir(mode=0o700)
        (target / "key").write_text("original identity\n")
        (target / "key").chmod(0o600)
        original = state.identity(target)
        snapshot = self.save()
        self.mutate()
        self.restore(snapshot)
        self.assertEqual(state.identity(target), original)
        self.assertEqual(self.env.read_bytes(), self.original)

    def test_mount_overlap_and_failed_inventory_refuse_snapshot(self):
        self.mounts = [{"Type": "bind", "Source": str(self.root)}]
        with self.assertRaisesRegex(ValueError, "overlaps"):
            self.save()
        self.mocked.side_effect = subprocess.CalledProcessError(1, ["synthetic"])
        with self.assertRaises(subprocess.CalledProcessError):
            self.save()
        self.assertEqual(self.env.read_bytes(), self.original)

    def test_tmpfs_has_no_host_source_and_does_not_expose_snapshot(self):
        mounted = self.root / "mounted"
        mounted.mkdir()
        self.mounts = [
            {"Type": "tmpfs", "Source": "", "Destination": "/tmp"},  # noqa: S108
            {"Type": "bind", "Source": str(mounted)},
        ]
        snapshot = self.save()
        self.assertTrue(snapshot.is_dir())

    def test_symlink_identity_and_damaged_snapshot_are_refused(self):
        (self.tor / "dashboard").symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "inode"):
            self.save()
        (self.tor / "dashboard").unlink()
        snapshot = self.save()
        (snapshot / "env").write_text("damaged\n")
        with self.assertRaisesRegex(ValueError, "damaged"):
            state.load(snapshot)
        self.assertTrue(snapshot.exists())

    def test_partial_restore_keeps_backup_and_can_resume(self):
        snapshot = self.save()
        self.mutate()
        with patch.object(state, "atomic_copy", side_effect=OSError("injected failure")):
            with self.assertRaises(OSError):
                self.restore(snapshot)
        self.assertEqual((snapshot / "env").read_bytes(), self.original)
        self.assertTrue((snapshot / "quarantine/key").is_file())
        self.restore(snapshot)
        self.assertEqual(self.env.read_bytes(), self.original)
        self.assertFalse((self.tor / "dashboard").exists())

    def test_unrelated_env_corruption_prevents_verification_and_cleanup(self):
        snapshot = self.save()
        self.mutate()
        metadata, target = state.load(snapshot)
        state.restore(snapshot, metadata, target)
        self.env.write_bytes(self.original + b"EXTRA=corruption\n")
        with self.assertRaisesRegex(ValueError, "differs"):
            state.verify(snapshot, metadata, target)
        with patch.object(state.sys, "argv", ["state", "cleanup", str(snapshot)]):
            with self.assertRaisesRegex(ValueError, "invalid"):
                state.main()
        self.assertTrue(snapshot.exists())


if __name__ == "__main__":
    unittest.main()
