"""Local contracts for live backup decryption and preservation of existing archives."""

import importlib.util
import json
import os
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(__file__).parents[1] / "tools/backup-ownership-probe.py"
spec = importlib.util.spec_from_file_location("backup_ownership_probe", SOURCE)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class BackupOwnershipProbe(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.original_cwd = Path.cwd()
        os.chdir(self.scratch.name)
        self.addCleanup(os.chdir, self.original_cwd)
        self.addCleanup(self.scratch.cleanup)

    @staticmethod
    def encrypt():
        subprocess.run(
            [
                "/usr/bin/openssl",
                "enc",
                "-aes-256-cbc",
                "-pbkdf2",
                "-iter",
                "600000",
                "-pass",
                "stdin",
                "-in",
                "plain.tar.gz",
                "-out",
                "archive.enc",
            ],
            input=b"fixture-passphrase\n",
            check=True,
            capture_output=True,
        )

    def test_streaming_archive_requires_its_own_passphrase(self):
        Path("config.json").write_text("{}")
        with tarfile.open("plain.tar.gz", "w:gz") as archive:
            archive.add("config.json")
        self.encrypt()
        self.assertEqual(
            probe.members(Path("archive.enc"), "fixture-passphrase", False), ["config.json"]
        )
        with self.assertRaises(RuntimeError):
            probe.members(Path("archive.enc"), "wrong-passphrase", False)

    def test_member_listing_is_bounded_while_the_pipeline_is_running(self):
        with tarfile.open("plain.tar.gz", "w:gz") as archive:
            for number in range(1200):
                archive.addfile(tarfile.TarInfo(f"{number}-" + "a" * 1000))
        self.encrypt()
        with self.assertRaises(RuntimeError):
            probe.members(Path("archive.enc"), "fixture-passphrase", False)

    def fixture(self, *, armed):
        Path("backups").mkdir()
        Path("backups/safety.tar.gz").write_bytes(b"original safety archive")
        original = Path("backups").stat()
        state = {
            "control": str(Path.cwd() / "control"),
            "requests": [],
            "armed": armed,
            "had_backups": True,
            "original": [
                original.st_uid,
                original.st_gid,
                stat.S_IMODE(original.st_mode),
                original.st_ino,
            ],
        }
        root = Path(".backup-ownership-fixture")
        root.mkdir()
        (root / "state.json").write_text(json.dumps(state))
        probe.MARKER.write_text(root.name)
        return root

    @staticmethod
    def local_command(args, **_kwargs):
        if args[:2] == ["systemctl", "show"]:
            return subprocess.CompletedProcess(args, 0, b"inactive\n")
        if args[:2] == ["rm", "-f"]:
            Path(args[-1]).unlink(missing_ok=True)
        elif args[:2] == ["rm", "-rf"]:
            shutil.rmtree(args[-1], ignore_errors=True)
        elif args[:2] == ["cp", "-p"]:
            shutil.copy2(args[-2], args[-1])
        elif args[:2] == ["tail", "-c"]:
            return subprocess.CompletedProcess(args, 0, Path(args[-1]).read_bytes()[-1048576:])
        else:
            raise AssertionError(args)
        return subprocess.CompletedProcess(args, 0, b"")

    def test_cleanup_recovers_rename_before_armed_state_was_saved(self):
        root = self.fixture(armed=False)
        Path("backups").rename(root / "backups")
        Path("backups").mkdir()
        Path("backups/test.enc").write_bytes(b"test archive")
        with patch.object(probe, "command", self.local_command):
            probe.cleanup()
        self.assertEqual(Path("backups/safety.tar.gz").read_bytes(), b"original safety archive")
        self.assertFalse(Path("backups/test.enc").exists())
        self.assertFalse(root.exists())
        self.assertFalse(probe.MARKER.exists())

    def test_unarmed_cleanup_does_not_delete_the_original_directory(self):
        self.fixture(armed=False)
        with patch.object(probe, "command", self.local_command):
            probe.cleanup()
        self.assertEqual(Path("backups/safety.tar.gz").read_bytes(), b"original safety archive")

    def test_failed_cleanup_retains_the_preserved_safety_archive(self):
        root = self.fixture(armed=True)
        Path("backups").rename(root / "backups")
        with (
            patch.object(probe, "wait_runner"),
            patch.object(probe, "command", return_value=subprocess.CompletedProcess([], 1)),
        ):
            with self.assertRaises(RuntimeError):
                probe.cleanup()
        self.assertEqual((root / "backups/safety.tar.gz").read_bytes(), b"original safety archive")
        self.assertTrue(probe.MARKER.exists())

    def test_cleanup_refuses_a_marker_pointing_outside_its_fixture(self):
        probe.MARKER.write_text("../outside")
        with self.assertRaises(RuntimeError):
            probe.cleanup()

    def test_cleanup_refuses_a_dangling_marker_symlink(self):
        probe.MARKER.symlink_to("missing")
        with self.assertRaises(RuntimeError):
            probe.cleanup()

    def test_cleanup_refuses_a_fixture_symlink(self):
        Path("outside").mkdir()
        Path(".backup-ownership-fixture").symlink_to("outside")
        probe.MARKER.write_text(".backup-ownership-fixture")
        with self.assertRaises(RuntimeError):
            probe.cleanup()

    def test_lost_post_reply_recovers_only_its_own_backup_from_the_audit(self):
        root = self.fixture(armed=True)
        state_file = root / "state.json"
        state = json.loads(state_file.read_text())
        state.update(actor=root.name, post_pending=True)
        state_file.write_text(json.dumps(state))
        Path("control/results").mkdir(parents=True)
        Path("control/audit").mkdir()
        owned = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        other = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        for request_id in (owned, other):
            for suffix in (".json", ".tar.gz.enc"):
                Path(f"control/results/{request_id}{suffix}").write_bytes(b"fixture")
        Path("control/audit/control.log").write_text(
            "\n".join(
                json.dumps({"actor": actor, "action": "backup", "id": request_id})
                for actor, request_id in (("another-actor", other), (root.name, owned))
            )
        )
        with patch.object(probe, "command", self.local_command):
            probe.cleanup()
        for suffix in (".json", ".tar.gz.enc"):
            self.assertFalse(Path(f"control/results/{owned}{suffix}").exists())
            self.assertTrue(Path(f"control/results/{other}{suffix}").exists())
        self.assertEqual(Path("backups/safety.tar.gz").read_bytes(), b"original safety archive")

    def test_stamp_restoration_survives_a_later_cleanup_failure_and_replay(self):
        root = self.fixture(armed=False)
        Path("control/staged").mkdir(parents=True)
        (root / "stamp").write_bytes(b"original throttle stamp")
        state_file = root / "state.json"
        original_state = state_file.read_text()
        broken_state = json.loads(original_state)
        broken_state["original"][3] += 1
        state_file.write_text(json.dumps(broken_state))
        with patch.object(probe, "command", self.local_command):
            with self.assertRaises(RuntimeError):
                probe.cleanup()
            self.assertTrue((root / "stamp").exists())
            state_file.write_text(original_state)
            probe.cleanup()
        self.assertEqual(
            Path("control/staged/.backup-stamp").read_bytes(), b"original throttle stamp"
        )

    def test_originally_absent_directory_must_be_absent_after_cleanup(self):
        root = self.fixture(armed=True)
        state = json.loads((root / "state.json").read_text())
        state.update(had_backups=False, original=None)
        (root / "state.json").write_text(json.dumps(state))
        with (
            patch.object(probe, "wait_runner"),
            patch.object(probe, "command", return_value=subprocess.CompletedProcess([], 0)),
        ):
            with self.assertRaises(RuntimeError):
                probe.cleanup()
        with patch.object(probe, "command", self.local_command):
            probe.cleanup()
        self.assertFalse(Path("backups").exists())

    def test_cleanup_replay_precedes_a_failing_fixture_apply(self):
        helper = SOURCE.parents[1] / "lib/run-backup-ownership.sh"
        Path("tools").mkdir()
        Path("tools/backup-ownership-probe.py").write_text("")
        result = subprocess.run(  # noqa: S603
            [
                "/bin/bash",
                "-c",
                """
INTEGRATION_RUN_SUITE=1 IT_FAIL=0 BASELINE_CONFIG='{}' HERE="$PWD" OUT_DIR="$PWD"
source "$1"
rx() { cat >/dev/null; printf '%s\n' "$1" >>calls; }
push_config() { echo apply >>calls; return 1; }
it_fail() { IT_FAIL=$((IT_FAIL + 1)); }
run_backup_ownership
""",
                "selftest",
                str(helper),
            ],
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            Path("calls").read_text().splitlines(), ["python3 - --cleanup", "apply", "apply"]
        )


if __name__ == "__main__":
    unittest.main()
