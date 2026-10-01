"""Exercise the real shared restart observer and wrapper against bounded fakes."""

import importlib.util
import json
import os
import subprocess
import tarfile
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
TOKEN = "a" * 32


class BackupBoundaryTests(unittest.TestCase):
    def test_real_restart_boundary_has_fixed_failure_observations(self):
        with tempfile.TemporaryDirectory() as sandbox:
            docker = Path(sandbox) / "docker"
            snapshot = {
                "container_id": "b" * 64,
                "image_id": "sha256:" + "c" * 64,
                "test": ["CMD", "/usr/local/bin/healthcheck.sh"],
                "health": "unhealthy",
                "checks": [None],
            }
            docker.write_text(
                '#!/bin/sh\ncase "$1" in\ninspect) cat "$SNAPSHOT";;\nexec) printf "%s  /usr/local/bin/healthcheck.sh\\n" "'
                + "d" * 64
                + '";;\nesac\n'
            )
            docker.chmod(0o700)
            data = Path(sandbox) / "snapshot.json"
            data.write_text(json.dumps(snapshot))
            script = """
source lib/pithead/17b-backup-window.sh
source lib/pithead/17a-backup-diagnostics.sh
backup_stack_up() { return 7; }
backup_diagnose_tor() { echo "changing private diagnostic tail" >&2; }
backup_recover_tor_state() { :; }
is_appliance() { return 1; }
warn() { :; }
backup_window_observe backup_begin
backup_restart_stack
"""
            process = subprocess.run(  # noqa: S603 - fixed fixture commands
                ["/bin/bash", "-c", script],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
                env={
                    **os.environ,
                    "PATH": sandbox + ":" + os.environ["PATH"],
                    "SNAPSHOT": str(data),
                    "PITHEAD_BACKUP_WINDOW_TOKEN": TOKEN,
                },
            )
            self.assertEqual(process.returncode, 1)
            lines = process.stdout.splitlines()
            values = [
                window.validate_observation(json.loads(line[len(window.PREFIX) :]), TOKEN)
                for line in lines
            ]
            self.assertEqual(
                [value["kind"] for value in values],
                [
                    "backup_begin",
                    "restart_before",
                    "restart_failed",
                    "restart_before",
                    "restart_failed",
                ],
            )
            self.assertEqual(values[-1]["implementation_sha256"], "d" * 64)
            self.assertNotIn("changing private", process.stdout)
            result = window.finish(window.new_result(TOKEN), 7, True, process.stdout)
            self.assertEqual(result["tor_event"], "tor_restart_failed")
            # An unavailable inspect cannot be converted into a Tor failure.
            data.write_text("broken")
            process = subprocess.run(  # noqa: S603 - fixed fixture commands
                ["/bin/bash", "-c", script],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
                env={
                    **os.environ,
                    "PATH": sandbox + ":" + os.environ["PATH"],
                    "SNAPSHOT": str(data),
                    "PITHEAD_BACKUP_WINDOW_TOKEN": TOKEN,
                },
            )
            result = window.finish(window.new_result(TOKEN), 7, True, process.stdout)
            self.assertEqual(result["tor_event"], "unknown")
            self.assertEqual(result["backup_exit_code"], 7)

    def test_observer_disabled_and_failed_diagnostics_do_not_change_startup(self):
        script = """
source lib/pithead/17b-backup-window.sh
source lib/pithead/17a-backup-diagnostics.sh
backup_stack_up() { return 0; }
backup_restart_stack
"""
        for token in ("", "private.internal", TOKEN):
            process = subprocess.run(  # noqa: S603 - fixed fixture commands
                ["/bin/bash", "-c", script],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
                env={
                    **os.environ,
                    "PITHEAD_BACKUP_WINDOW_TOKEN": token,
                    "PATH": "/nonexistent",
                    "BASH_ENV": "",
                },
                executable="/bin/bash",
            )
            self.assertEqual(process.returncode, 0)
            self.assertEqual(process.stdout, "")

    def test_final_record_preserves_code_if_result_or_artifact_writes_fail(self):
        with tempfile.TemporaryDirectory() as parent:
            with patch("builtins.print") as output:
                window.initialize(parent)
            directory = Path(output.call_args.args[0])
            with (
                patch("sys.argv", ["producer", "finish", str(directory), "7", "invalid"]),
                patch("sys.stdin") as stdin,
                patch("builtins.print") as output,
                patch.object(window, "atomic_write", side_effect=OSError),
            ):
                stdin.read.return_value = "changing failure tail"
                window.main()
            frame = output.call_args_list[0].args[0]
            result = json.loads(frame[len(window.RESULT) :])
            self.assertEqual(result["backup_exit_code"], 7)
            self.assertEqual(result["diagnostics"]["availability"], "unavailable")
            # Corrupted or absent result files also retain the numeric original outcome.
            (directory / "result.json").unlink()
            with (
                patch("sys.argv", ["producer", "finish", str(directory), "9", "invalid"]),
                patch("sys.stdin") as stdin,
                patch("builtins.print") as output,
            ):
                stdin.read.return_value = "original failure"
                window.main()
            result = json.loads(output.call_args_list[0].args[0][len(window.RESULT) :])
            self.assertEqual(result["backup_exit_code"], 9)

    def test_result_rejects_unsafe_or_stale_artifact_references(self):
        with tempfile.TemporaryDirectory() as parent:
            with patch("builtins.print") as output:
                window.initialize(parent)
            directory, value = window.read(output.call_args.args[0])
            for artifact in (
                "../backup.log",
                "/home/user/backup.log",
                "backup-window-" + "b" * 32 + "/backup.log",
                "host.internal/key",
                "cookie=secret",
                "x" * 9000,
                "\x1b",
            ):
                value["diagnostics"] = {"availability": "available", "artifact": artifact}
                with self.assertRaises(ValueError):
                    window.validate_result(value, directory)
            value["diagnostics"] = {
                "availability": "available",
                "artifact": directory.name + "/backup.log",
            }
            with self.assertRaises(ValueError):
                window.validate_result(value, directory)
            (directory / "backup.log").symlink_to(directory / "result.json")
            with self.assertRaises(ValueError):
                window.validate_result(value, directory)

    def test_wrapper_outcomes_and_diagnostics_failure(self):
        with tempfile.TemporaryDirectory() as parent:
            canonical = Path(parent) / "canonical"
            baseline = Path(parent) / "baseline"
            canonical.mkdir()
            baseline.mkdir()
            fake = canonical / "pithead"
            fake.write_text("""#!/bin/bash
case "$FAKE_MODE" in
error) echo 'original failure'; exit 7;;
success|diagnostic-failure) mkdir -p backups; tar -czf backups/pithead-backup-fixture.tar.gz pithead;;
corrupt) mkdir -p backups; echo broken >backups/pithead-backup-fixture.tar.gz;;
missing|stale) :;;
esac
""")
            fake.chmod(0o700)
            (baseline / "pithead").write_text("different live baseline executable")
            script = """
set -uo pipefail
HERE="$PWD/tests/integration"
source "$HERE/lib.sh"
source "$HERE/lib/remote-endpoints.sh"
source "$HERE/lib/backup-window.sh"
log() { :; }
ok() { :; }
die() { echo "$*" >&2; exit 1; }
on_bench() { /bin/bash -c "$1"; }
backup_window_init
if [ "$FAKE_MODE" = diagnostic-failure ]; then backup_sanitize_output() { return 1; }; fi
eval "$(sed -n '/^backup_stack() {$/,/^}$/p' "$HERE/lib/safety-backup.sh")"
backup_stack
"""
            for mode, code, outcome in (
                ("error", 7, "failed"),
                ("success", 0, "succeeded"),
                ("missing", 0, "failed"),
                ("stale", 0, "failed"),
                ("corrupt", 0, "failed"),
                ("diagnostic-failure", 0, "succeeded"),
            ):
                for archive in canonical.glob("backups/*"):
                    archive.unlink()
                if mode == "stale":
                    archive = canonical / "backups/pithead-backup-old.tar.gz"
                    archive.parent.mkdir(exist_ok=True)
                    with tarfile.open(archive, "w:gz") as stream:
                        stream.add(fake, arcname="pithead")
                    os.utime(archive, (1, 1))
                process = subprocess.run(  # noqa: S603 - fixed fixture commands
                    ["/bin/bash", "-c", script],
                    cwd=ROOT,
                    capture_output=True,
                    text=True,
                    check=False,
                    env={
                        **os.environ,
                        "FAKE_MODE": mode,
                        "CANONICAL_DIR": str(canonical),
                        "RESTORE_DIR": str(baseline),
                        "IT_BACKUP_WINDOW_DIR": parent,
                    },
                )
                frames = [
                    json.loads(line[len(window.RESULT) :])
                    for line in process.stdout.splitlines()
                    if line.startswith(window.RESULT)
                ]
                self.assertEqual(len(frames), 3, process.stderr)
                result = frames[-1]
                self.assertEqual(result["backup_exit_code"], code)
                self.assertEqual(result["outcome"], outcome)
                self.assertEqual(process.returncode, 0 if outcome == "succeeded" else 1)
                self.assertNotEqual(
                    result["canonical_product"]["executable_sha256"],
                    result["baseline_product"]["executable_sha256"],
                )
                self.assertEqual(result["tor_event"], "unknown")
                artifact_dir = Path(parent) / ("backup-window-" + result["invocation"])
                self.assertFalse((artifact_dir / "original.log").exists())
                if mode == "diagnostic-failure":
                    self.assertEqual(result["diagnostics"]["availability"], "unavailable")
                else:
                    self.assertTrue((Path(parent) / result["diagnostics"]["artifact"]).is_file())

    def test_check_mode_and_pre_backup_refusal_are_not_run(self):
        with tempfile.TemporaryDirectory() as parent:
            for mode in ("check", "targeted"):
                process = subprocess.run(  # noqa: S603 - fixed fixture commands
                    [
                        "/bin/bash",
                        "tests/integration/e2e.sh",
                        "candidate",
                        "--mode",
                        mode,
                        "--workers",
                        "0",
                    ],
                    cwd=ROOT,
                    capture_output=True,
                    text=True,
                    check=False,
                    env={**os.environ, "IT_BACKUP_WINDOW_DIR": parent},
                )
                frame = next(
                    line for line in process.stdout.splitlines() if line.startswith(window.RESULT)
                )
                result = json.loads(frame[len(window.RESULT) :])
                self.assertEqual(result["attempt"], "not_run")
                self.assertEqual(result["tor_event"], "unknown")
                self.assertEqual(result["execution"], "unknown")
            script = """
set -uo pipefail
HERE="$PWD/tests/integration"
source "$HERE/lib/backup-window.sh"
backup_window_init
MODE=check KEEP=0 BRANCH=candidate BENCH_HOST=fixture
log() { :; }
ok() { :; }
preflight() { :; }
provision() { :; }
run_harness() { :; }
backup_stack() { echo BACKUP_REACHED; }
borrow_miner() { echo BORROW_REACHED; }
deploy_branch() { echo DEPLOY_REACHED; }
eval "$(sed -n '/^main() {$/,/^}$/p' "$HERE/e2e.sh")"
main
"""
            process = subprocess.run(  # noqa: S603 - fixed fixture commands
                ["/bin/bash", "-c", script],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
                env={**os.environ, "IT_BACKUP_WINDOW_DIR": parent},
            )
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertNotIn("REACHED", process.stdout)
            frame = next(
                line for line in process.stdout.splitlines() if line.startswith(window.RESULT)
            )
            self.assertEqual(json.loads(frame[len(window.RESULT) :])["attempt"], "not_run")
