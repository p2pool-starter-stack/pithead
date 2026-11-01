import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = Path(os.environ.get("SELFTEST_MAKEFILE", ROOT / "Makefile"))


class SelftestRunnerTest(unittest.TestCase):
    def run_fixture(self, failures):
        section = MAKEFILE.read_text().split("test-integration-selftest:", 1)[1]
        recipe = section.split("\n\n", 1)[0].splitlines()[1:]
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / "Makefile").write_text(
                "test-integration-selftest:\n" + "\n".join(recipe) + "\n"
            )
            names = [
                "tests/integration/selftest/01-first.sh",
                "tests/integration/selftest/99-last.sh",
                "tests/os/selftest01-first.sh",
                "tests/os/selftest99-last.sh",
            ]
            for name in names:
                script = root / name
                script.parent.mkdir(parents=True, exist_ok=True)
                script.write_text(
                    'printf "%s\\n" "$0" >> calls\n'
                    'test "${SELFTEST_LEAK+x}${TMPDIR+x}${RUNNER_TEMP+x}${HOME+x}${BASH_ENV+x}" = "" || exit 81\n'
                    'test "$PATH" = /usr/local/bin:/usr/bin:/bin || exit 82\n'
                    f"exit {failures.get(name, 0)}\n"
                )
            result = subprocess.run(
                ["/usr/bin/make", "--no-print-directory", "test-integration-selftest"],
                cwd=root,
                env={**os.environ, "SELFTEST_LEAK": "must-disappear"},
                capture_output=True,
                text=True,
                timeout=20,
            )
            self.assertEqual((root / "calls").read_text().splitlines(), names)
            self.assertEqual(result.returncode == 0, not failures, result.stderr)
            for name, code in failures.items():
                self.assertIn(f"{name} failed (exit {code})", result.stderr)

    def test_all_pass_in_isolated_environment(self):
        self.run_fixture({})

    def test_integration_failure_keeps_both_globs_running(self):
        self.run_fixture({"tests/integration/selftest/01-first.sh": 7})

    def test_os_failure_keeps_later_files_running(self):
        self.run_fixture({"tests/os/selftest01-first.sh": 9})

    def test_multiple_failures_are_reported(self):
        self.run_fixture(
            {
                "tests/integration/selftest/01-first.sh": 7,
                "tests/os/selftest01-first.sh": 9,
            }
        )

    def test_tooling_gate_is_registered(self):
        self.assertIn(
            "\tpython3 tests/integration/test_selftest_runner.py\n",
            MAKEFILE.read_text().split("test-tools:", 1)[1].split("\n\n", 1)[0],
        )


if __name__ == "__main__":
    unittest.main()
