"""Destructive fixture round trip and fail-closed snapshot boundaries, without a wallet."""

import importlib.util
import io
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "wallet_fixture", Path(__file__).resolve().parents[1] / "lib/wallet-fixture.py"
)
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)
IMAGE = "sha256:" + "a" * 64


def archive(extra=None, keys=None):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w") as output:
        for name, contents in {
            "payout-wallet": b"cache\x00\xff",
            "payout-wallet.keys": b"dummy-view-only-keys",
            **(extra or {}),
        }.items():
            item = tarfile.TarInfo(name)
            item.uid = item.gid = 1000
            item.mode = 0o600
            if name == "payout-wallet.keys":
                for field, value in (keys or {}).items():
                    setattr(item, field, value)
            item.size = len(contents)
            output.addfile(item, io.BytesIO(contents))
    return data.getvalue()


class Docker:
    """Only the native operations used by one fixture; no host Docker or wallet access."""

    def __init__(self, baseline):
        self.calls = []
        self.dropped_terms = 0
        self.kills = 0
        self.race_on_kill = 0  # the Nth TERM finds the wallet already exiting from an earlier one
        self.contents = archive()
        self.volume_labels = {
            "com.docker.compose.project": "pithead",
            "com.docker.compose.volume": "wallet_data",
        }
        self.item = {
            "Id": "source",
            "Image": IMAGE,
            "State": {"Running": True, "ExitCode": 0, "OOMKilled": False},
            "Config": {
                "Env": (baseline / ".env").read_text().splitlines(),
                "Labels": {
                    "com.docker.compose.project": "pithead",
                    "com.docker.compose.service": "wallet-rpc",
                    "com.docker.compose.project.working_dir": str(baseline),
                },
            },
            "Mounts": [
                {"Destination": fixture.WALLET_DIR, "Type": "volume", "Name": fixture.VOLUME}
            ],
        }

    def __call__(self, *args, **kwargs):
        self.calls.append(args)
        value = b""
        if args[0] == "ps":
            value = b"source" if self.item else b""
        elif args[:2] == ("container", "inspect"):
            value = json.dumps([self.item]).encode()
        elif args[:2] == ("volume", "inspect"):
            value = json.dumps(
                [
                    {
                        "Driver": "local",
                        "Options": None,
                        "Labels": self.volume_labels,
                    }
                ]
            ).encode()
        elif args[:2] == ("image", "inspect"):
            value = json.dumps([{"Id": IMAGE}]).encode()
        elif args[0] == "kill":
            self.kills += 1
            if self.kills == self.race_on_kill:
                self.item["State"]["Running"] = False
                if kwargs.get("check", True):
                    raise subprocess.CalledProcessError(1, ["docker", *args])
                return subprocess.CompletedProcess(args, 1, b"")
            if self.dropped_terms > 0:  # TERM to a PID 1 that has no handler yet is discarded
                self.dropped_terms -= 1
            else:
                self.item["State"]["Running"] = False
        elif args[0] == "logs":
            value = b"Loading wallet...\n"
        elif args[0] == "start":
            self.item["State"]["Running"] = True
        elif args[:2] == ("image", "save"):
            kwargs["stdout"].write(b"dummy-pinned-image")
        elif args[0] == "run":
            if "--no-same-owner" in args[-1]:
                self.contents = kwargs["stdin"].read()
            else:
                kwargs["stdout"].write(self.contents)
        return subprocess.CompletedProcess(args, 0, value)


class FixtureTest(unittest.TestCase):
    def setUp(self):
        self.previous_umask = os.umask(0o077)
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.baseline = self.root / "baseline"
        self.baseline.mkdir()
        self.env = self.baseline / ".env"
        self.env.write_text(
            "MONERO_WALLET_ADDRESS=dummy-address\nMONERO_VIEW_KEY=dummy-view-key\nPAYOUT_SCAN_HEIGHT=42\nWALLET_RPC_USERNAME=dummy-user\nWALLET_RPC_PASSWORD=dummy-password\n"
        )
        self.docker = Docker(self.baseline)
        self.mock_docker = patch.object(fixture, "docker", self.docker)
        self.mock_docker.start()
        self.mock_tmp = patch.dict(os.environ, {"IT_SCRATCH_DIR": str(self.root)})
        self.mock_tmp.start()
        self.mock_sleep = patch.object(fixture.time, "sleep")
        self.mock_sleep.start()

    def tearDown(self):
        self.mock_sleep.stop()
        self.mock_tmp.stop()
        self.mock_docker.stop()
        self.temporary.cleanup()
        os.umask(self.previous_umask)

    def capture(self):
        with patch("sys.stdout", io.StringIO()) as output:
            fixture.capture(self.baseline)
        return Path(output.getvalue().strip())

    def test_capture_resends_term_until_the_wallet_installs_its_handler_and_never_kills(self):
        self.docker.dropped_terms = 2
        clock = iter(range(0, 1000, 5))
        with patch.object(fixture.time, "monotonic", side_effect=lambda: next(clock)):
            self.capture()
        kills = [call for call in self.docker.calls if call[0] == "kill"]
        self.assertEqual(len(kills), 3)
        self.assertTrue(all(call[1:3] == ("--signal", "TERM") for call in kills))
        self.assertFalse(any(call[0] == "stop" for call in self.docker.calls))

    def test_a_resend_racing_the_wallet_exit_is_not_a_capture_failure(self):
        self.docker.dropped_terms = 1
        self.docker.race_on_kill = 2
        clock = iter(range(0, 1000, 5))
        with patch.object(fixture.time, "monotonic", side_effect=lambda: next(clock)):
            self.capture()
        self.assertEqual(len([call for call in self.docker.calls if call[0] == "kill"]), 2)
        self.assertFalse(any(call[0] == "stop" for call in self.docker.calls))

    def test_capture_gives_up_without_a_forced_kill_and_dumps_the_wallet_log(self):
        self.docker.dropped_terms = 10**6
        clock = iter(range(0, 10000, 5))
        with patch.object(fixture.time, "monotonic", side_effect=lambda: next(clock)):
            with patch("sys.stderr", io.StringIO()) as err:
                with self.assertRaisesRegex(ValueError, "no forced kill attempted"):
                    fixture.capture(self.baseline)
        self.assertIn("Loading wallet...", err.getvalue())
        self.assertFalse(any(call[0] == "stop" for call in self.docker.calls))
        kills = [call for call in self.docker.calls if call[0] == "kill"]
        self.assertTrue(kills and all(call[1:3] == ("--signal", "TERM") for call in kills))

    def test_uninstall_recreates_cold_volume_then_exact_fixture_returns(self):
        directory = self.capture()
        saved = self.docker.contents
        self.assertTrue(self.docker.item["State"]["Running"])
        self.docker.item = None  # uninstall removes the consumer and named volume
        self.docker.contents = archive({"cold-scan-marker": b"cold"})
        fixture.restore(directory, self.baseline, self.root / "branch")
        self.assertEqual(self.docker.contents, saved)
        self.assertEqual(fixture.load(directory, self.baseline)["stage"], "import_verified")
        runs = [call for call in self.docker.calls if call[0] == "run"]
        for call in runs:
            self.assertEqual(call[call.index("--network") + 1], "none")
            self.assertEqual(call[call.index("--user") + 1], "1000:1000")
            self.assertIn("--read-only", call)
            self.assertEqual(call[call.index("--cap-drop") + 1], "ALL")
            self.assertEqual(call[-3], IMAGE)
        fixture.cleanup(directory, self.baseline)
        self.assertEqual({path.name for path in directory.iterdir()}, {"state.json"})
        self.assertEqual(
            fixture.load(directory, self.baseline, cleanup_only=True)["stage"], "ready"
        )
        fixture.cleanup(
            directory, self.baseline
        )  # replay completes even after archives were removed

    def test_identity_or_snapshot_changes_refuse_before_any_restore_mutation(self):
        directory = self.capture()
        original = self.env.read_text()
        for field in (
            "MONERO_WALLET_ADDRESS",
            "MONERO_VIEW_KEY",
            "PAYOUT_SCAN_HEIGHT",
            "WALLET_RPC_USERNAME",
            "WALLET_RPC_PASSWORD",
        ):
            self.env.write_text(original.replace(field + "=", field + "=changed-"))
            before = len(self.docker.calls)
            with self.assertRaises(ValueError):
                fixture.restore(directory, self.baseline, self.root / "branch")
            self.assertEqual(len(self.docker.calls), before)
        self.env.write_text(original)
        for name in ("wallet.tar", "image.tar"):
            path = directory / name
            saved = path.read_bytes()
            path.write_bytes(saved + b"tampered")
            before = len(self.docker.calls)
            with self.assertRaises(ValueError):
                fixture.restore(directory, self.baseline, self.root / "branch")
            self.assertEqual(len(self.docker.calls), before)
            path.write_bytes(saved)

    def test_unprepared_or_foreign_wallet_is_never_copied(self):
        self.docker.contents = archive({".payout-scanning": b""})
        with self.assertRaises(ValueError):
            self.capture()
        self.assertTrue(self.docker.item["State"]["Running"])
        self.assertFalse(list(self.root.glob("pithead-wallet-fixture-*")))
        self.docker.contents = archive()
        self.docker.item["Config"]["Labels"]["com.docker.compose.project.working_dir"] = "/other"
        before = len(self.docker.calls)
        with self.assertRaises(ValueError):
            self.capture()
        self.assertFalse(any(call[0] in {"stop", "run"} for call in self.docker.calls[before:]))
        self.docker.item["Config"]["Labels"]["com.docker.compose.project.working_dir"] = str(
            self.baseline
        )
        self.docker.item["Config"]["Env"] = self.env.read_text().splitlines()
        self.docker.volume_labels["com.docker.compose.project"] = "another-project"
        before = len(self.docker.calls)
        with self.assertRaises(ValueError):
            self.capture()
        self.assertFalse(any(call[0] in {"stop", "run"} for call in self.docker.calls[before:]))
        self.docker.item["Config"]["Labels"]["com.docker.compose.project.working_dir"] = str(
            self.baseline
        )
        self.docker.item["Config"]["Env"][0] = "MONERO_WALLET_ADDRESS=another-address"
        before = len(self.docker.calls)
        with self.assertRaises(ValueError):
            self.capture()
        self.assertFalse(any(call[0] in {"stop", "run"} for call in self.docker.calls[before:]))

    def test_private_snapshot_and_archive_types_are_binding(self):
        directory = self.capture()
        directory.chmod(0o755)
        with self.assertRaises(ValueError):
            fixture.load(directory, self.baseline)
        directory.chmod(0o700)
        for name in ("../escape", "/absolute", ".payout-scanning", "foreign-wallet.keys"):
            path = self.root / "unsafe.tar"
            path.write_bytes(archive({name: b"bad"}))
            with self.assertRaises(ValueError):
                fixture.manifest(path)
        path = self.root / "symlink.tar"
        with tarfile.open(path, "w") as output:
            item = tarfile.TarInfo("link")
            item.type = tarfile.SYMTYPE
            item.linkname = "../escape"
            output.addfile(item)
        with self.assertRaises(ValueError):
            fixture.manifest(path)
        # Otherwise complete archives, so only the ownership/mode guard can refuse them.
        for keys in ({"mode": 0o644}, {"uid": 0}, {"gid": 0}):
            path = self.root / "foreign-owner.tar"
            path.write_bytes(archive(keys=keys))
            with self.assertRaisesRegex(ValueError, "ownership or mode"):
                fixture.manifest(path)
        with self.assertRaises(ValueError):
            fixture.cleanup(directory, self.baseline)
        self.assertTrue((directory / "wallet.tar").exists())

    def test_partial_cleanup_can_be_replayed_after_durable_readiness(self):
        directory = self.capture()
        fixture.restore(directory, self.baseline, self.root / "branch")
        state = fixture.load(directory, self.baseline)
        state["stage"] = "ready"
        fixture.write_state(directory, state)
        (directory / "wallet.tar").unlink()  # power loss between the two archive removals
        fixture.cleanup(directory, self.baseline)
        self.assertEqual({path.name for path in directory.iterdir()}, {"state.json"})
        self.assertEqual(
            fixture.load(directory, self.baseline, cleanup_only=True)["stage"], "ready"
        )

    def test_durable_receipt_precedes_destructive_work_and_is_owner_only(self):
        fixture.receipt(self.root, "ARMED")
        path = self.root / "wallet-fixture-restore.state"
        self.assertEqual(path.read_bytes(), b"ARMED\n")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(ValueError):
            fixture.receipt(self.root, "ARMED")
        with self.assertRaises(ValueError):
            fixture.receipt(self.root, "VERIFIED")  # verification needs durable readiness first
        self.assertEqual(path.read_bytes(), b"ARMED\n")
        fixture.receipt(self.root, "READY")
        fixture.receipt(self.root, "VERIFIED")
        self.assertEqual(path.read_bytes(), b"VERIFIED\n")
        fixture.receipt(
            self.root, "ARMED"
        )  # normal same-job readiness retry after proved restoration
        self.assertEqual(path.read_bytes(), b"ARMED\n")
        self.root.chmod(0o777)
        with self.assertRaises(ValueError):
            fixture.receipt(self.root, "ARMED")
        self.root.chmod(0o700)

    def test_restarting_wallet_never_allows_a_volume_import(self):
        directory = self.capture()
        self.docker.item["State"].update(Running=False, Restarting=True)
        before = len(self.docker.calls)
        with patch.object(fixture.time, "monotonic", side_effect=[0, 601]):
            with self.assertRaises(ValueError):
                fixture.restore(directory, self.baseline, self.root / "branch")
        self.assertFalse(any(call[0] == "run" for call in self.docker.calls[before:]))


if __name__ == "__main__":
    unittest.main()
