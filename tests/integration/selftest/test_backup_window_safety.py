"""Adversarial result-storage and semantic-validation fixtures."""

import copy
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).parents[3]
SPEC = importlib.util.spec_from_file_location(
    "backup_window", ROOT / "tests/integration/lib/backup-window.py"
)
window = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(window)


class BackupStorageTests(unittest.TestCase):
    def test_inaccessible_root_has_only_fixed_diagnostics(self):
        script = (
            'HERE="$PWD/tests/integration"; source "$HERE/lib/backup-window.sh"; backup_window_init'
        )
        with tempfile.TemporaryDirectory() as parent:
            # Inject an inaccessible-path failure even when the test user is root.
            (Path(parent) / "sitecustomize.py").write_text(
                "from pathlib import Path\n"
                "def denied(self): raise PermissionError('private inaccessible path')\n"
                "Path.is_symlink = denied\n"
            )
            env = {**os.environ, "CI_ARTIFACTS": parent, "PYTHONPATH": parent}
            env.pop("IT_BACKUP_WINDOW_DIR", None)
            process = subprocess.run(  # noqa: S603 - fixed fixture command
                ["/bin/bash", "-c", script],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(process.returncode, 0)
            self.assertEqual(process.stderr, "Backup-window diagnostics unavailable.\n")
            facts = json.loads(process.stdout.removeprefix("Backup-window storage refused: "))
            self.assertEqual(facts, {"absolute": True, "stat_available": False})
            self.assertNotIn(parent, process.stdout + process.stderr)
            self.assertNotIn("private inaccessible path", process.stdout + process.stderr)

    def test_runner_artifact_root_and_refusal_diagnostics(self):
        script = (
            'HERE="$PWD/tests/integration"; source "$HERE/lib/backup-window.sh"; backup_window_init'
        )
        with tempfile.TemporaryDirectory() as parent:
            env = {**os.environ, "CI_ARTIFACTS": parent}
            env.pop("IT_BACKUP_WINDOW_DIR", None)
            for mode in (0o755, 0o775):
                os.chmod(parent, mode)  # noqa: S103 - safe/refused storage fixtures
                process = subprocess.run(  # noqa: S603 - fixed fixture command
                    ["/bin/bash", "-c", script],
                    cwd=ROOT,
                    env=env,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(process.returncode, 0)
                if mode == 0o755:
                    value = json.loads(process.stdout.removeprefix(window.RESULT))
                    self.assertEqual(value["attempt"], "not_run")
                    self.assertTrue(
                        (
                            Path(parent) / ("backup-window-" + value["invocation"]) / "result.json"
                        ).is_file()
                    )
                else:
                    self.assertIn("Backup-window diagnostics unavailable.", process.stderr)
                    facts = json.loads(
                        process.stdout.removeprefix("Backup-window storage refused: ")
                    )
                    self.assertEqual(
                        facts,
                        {
                            "absolute": True,
                            "symlink": False,
                            "directory": True,
                            "owned": True,
                            "writable_by_others": True,
                        },
                    )
                    self.assertNotIn(parent, process.stdout + process.stderr)
                    self.assertNotIn(window.RESULT, process.stdout)
            os.chmod(parent, 0o700)

    def test_unsafe_directory_does_not_receive_writes_but_keeps_original_exit(self):
        with tempfile.TemporaryDirectory() as parent:
            outside = Path(parent) / "outside"
            outside.mkdir()
            link = Path(parent) / ("backup-window-" + "a" * 32)
            link.symlink_to(outside, target_is_directory=True)
            for action in ("diagnostics", "finish"):
                with (
                    patch("sys.argv", ["producer", action, str(link), "7", "invalid"]),
                    patch("sys.stdin", io.StringIO("original failure")),
                    patch("builtins.print") as output,
                ):
                    if action == "diagnostics":
                        with self.assertRaises(OSError):
                            window.main()
                    else:
                        window.main()
                        result = json.loads(output.call_args.args[0][len(window.RESULT) :])
                        self.assertEqual(result["backup_exit_code"], 7)
                        self.assertEqual(result["diagnostics"]["availability"], "unavailable")
                self.assertEqual(list(outside.iterdir()), [])

    def test_symlink_artifact_is_replaced_without_overwriting_target(self):
        with tempfile.TemporaryDirectory() as parent:
            with patch("builtins.print") as output:
                window.initialize(parent)
            directory = Path(output.call_args.args[0])
            outside = Path(parent) / "outside"
            outside.write_text("preserve this file")
            artifact = directory / "backup.log"
            artifact.symlink_to(outside)
            with (
                patch("sys.argv", ["producer", "diagnostics", str(directory)]),
                patch("sys.stdin", io.StringIO("sanitized diagnostics")),
            ):
                window.main()
            self.assertFalse(artifact.is_symlink())
            self.assertEqual(artifact.read_text(), "sanitized diagnostics")
            self.assertEqual(outside.read_text(), "preserve this file")
            self.assertEqual(artifact.stat().st_mode & 0o777, 0o600)

    def test_contradictory_or_unsupported_result_is_rejected(self):
        with tempfile.TemporaryDirectory() as parent:
            with patch("builtins.print") as output:
                window.initialize(parent)
            directory, initial = window.read(output.call_args.args[0])
            for changes in (
                {"outcome": "succeeded"},
                {
                    "attempt": "attempted",
                    "outcome": "succeeded",
                    "backup_exit_code": 7,
                    "reason": "archive_valid",
                },
                {"attempt": "not_run", "backup_exit_code": 0},
                {"execution": "observed"},
                {"tor_event": "tor_restart_failed"},
                {"observation_channel": "available"},
                {
                    "attempt": "attempted",
                    "outcome": "failed",
                    "backup_exit_code": 0,
                    "reason": "command_failed",
                },
            ):
                value = copy.deepcopy(initial)
                value.update(changes)
                with self.assertRaises(ValueError):
                    window.validate_result(value, directory)
            valid = window.finish(copy.deepcopy(initial), 7, False, "original failure")
            window.validate_result(valid, directory)
