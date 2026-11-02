import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# ruff: noqa: S108, S603, S607

ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "tests/go-parity/keep_running_reference.sh"


def wrapper(directory, binary):
    calls = directory / "calls"
    statuses = directory / "statuses"
    path = directory / "pithead"
    path.write_text(
        "#!/bin/sh\n"
        f'if [ "$PITHEAD_GO_HELPER" != keep-running-scope ]; then exec "{binary}" "$@"; fi\n'
        f'printf "%s\\n" "$PITHEAD_GO_HELPER" >> "{calls}"\n'
        f'"{binary}" "$@"\n'
        "rc=$?\n"
        f'printf "%s %d\\n" "$PITHEAD_GO_HELPER" "$rc" >> "{statuses}"\n'
        'exit "$rc"\n'
    )
    path.chmod(0o755)
    return path, calls, statuses


def run(binary, directory):
    path, calls, statuses = wrapper(directory, binary)
    fragments = directory / "fragments"
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL="go",
        PITHEAD_GO_BINARY=str(path),
        PITHEAD_GO_CONFIG_DOCUMENT_BINARY=str(path),
        PITHEAD_SCOPE_CALL_LOG=str(calls),
        PITHEAD_SCOPE_FRAGMENT_LOG=str(fragments),
        PITHEAD_UNTRUSTED_MACOS_RUN="1",
        RUNNER_TEMP="/tmp",
    )
    result = subprocess.run(
        ["bash", str(HARNESS)],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=180,
        check=False,
    )
    return result, calls, statuses, fragments


class KeepRunningScopeControls(unittest.TestCase):
    @unittest.skipUnless(
        sys.platform.startswith("linux") or os.environ.get("PITHEAD_SCOPE_FULL"), "Linux proof"
    )
    def test_full_oracle_and_fragment_guard(self):
        binary = Path(os.environ.get("PITHEAD_SCOPE_BINARY", ROOT / "go/bin/pithead"))
        with tempfile.TemporaryDirectory() as raw:
            result, calls, statuses, fragments = run(binary, Path(raw))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(calls.read_text().splitlines(), ["keep-running-scope"] * 4)
            self.assertEqual(statuses.read_text().splitlines(), ["keep-running-scope 0"] * 4)
            self.assertEqual(
                fragments.read_text().splitlines(),
                [
                    "lock-core 0 0",
                    "lock-wiring 0 0",
                    "keep-running 4 0",
                    "lan-guard 0 0",
                    "first-network 0 0",
                ],
            )

    @unittest.skipUnless(
        os.environ.get("PITHEAD_SCOPE_UNSUPPORTED_BINARY"), "no unsupported mutant"
    )
    def test_supported_exit_125_fails_strict_guard(self):
        binary = Path(os.environ["PITHEAD_SCOPE_UNSUPPORTED_BINARY"])
        with tempfile.TemporaryDirectory() as raw:
            result, calls, statuses, _ = run(binary, Path(raw))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(calls.read_text().splitlines(), ["keep-running-scope"] * 4)
            self.assertEqual(statuses.read_text().splitlines(), ["keep-running-scope 125"] * 4)

    @unittest.skipUnless(os.environ.get("PITHEAD_SCOPE_EMPTY_BINARY"), "no wrong-plan mutant")
    def test_wrong_plan_breaks_unchanged_oracle(self):
        binary = Path(os.environ["PITHEAD_SCOPE_EMPTY_BINARY"])
        with tempfile.TemporaryDirectory() as raw:
            result, _, statuses, _ = run(binary, Path(raw))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("✗", result.stdout)
            self.assertEqual(statuses.read_text().splitlines(), ["keep-running-scope 0"] * 4)


if __name__ == "__main__":
    unittest.main()
