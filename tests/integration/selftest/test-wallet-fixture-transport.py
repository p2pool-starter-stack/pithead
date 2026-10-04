"""Run the actual snapshot transport from a foreign cwd without an import search path."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]


class TransportTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.branch = self.root / "candidate checkout"
        self.lib = self.branch / "tests/integration/lib"
        self.lib.mkdir(parents=True)
        for name in ("wallet-fixture.py", "wallet_archive.py"):
            shutil.copyfile(HERE / "lib" / name, self.lib / name)
        self.baseline = self.root / "baseline stack"
        self.baseline.mkdir()
        # Disabled confirmation returns before Docker, but must load the complete helper.
        (self.baseline / ".env").write_text("MONERO_VIEW_KEY=\n")
        self.cwd = self.root / "remote cwd"
        self.cwd.mkdir()

    def run_capture(self):
        # Only the repository helper and test-owned temporary paths enter this command.
        return subprocess.run(  # noqa: S603
            [
                shutil.which("bash"),
                "-c",
                'HERE=$1; source "$HERE/lib.sh"; source "$HERE/lib/wallet-fixture.sh"; '
                'E2E_DIR=$2; RESTORE_DIR=$3; on_bench() { bash -c "$1"; }; '
                "wallet_fixture_command capture",
                "_",
                str(HERE),
                str(self.branch),
                str(self.baseline),
            ],
            cwd=self.cwd,
            env={**os.environ, "PYTHONPATH": ""},
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_command_loads_sibling_archive_module_from_candidate_checkout(self):
        result = self.run_capture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse((self.cwd / "wallet_archive.py").exists())

    def test_missing_candidate_dependency_fails_instead_of_skipping_snapshot(self):
        (self.lib / "wallet_archive.py").unlink()
        result = self.run_capture()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wallet_archive", result.stderr)


if __name__ == "__main__":
    unittest.main()
