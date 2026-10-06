"""Exercise fixture invocation and delayed-start ordering without starting containers."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = (Path(__file__).resolve().parents[1] / "payout-pairs/run.sh").read_text()


def function(name):
    return name + "() {" + SCRIPT.split(name + "() {", 1)[1].split("\n}\n", 1)[0] + "\n}\n"


class RuntimeTest(unittest.TestCase):
    def run_shell(self, source, extra=None):
        return subprocess.run(  # noqa: S603 — fixed test commands and repository fragments
            [shutil.which("bash"), "-euo", "pipefail", "-c", source],
            env={**os.environ, **(extra or {})},
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_apply_uses_caller_identity_for_owner_only_env(self):
        with tempfile.TemporaryDirectory() as work:
            trace = Path(work) / "trace"
            result = self.run_shell(
                "ROOT=fixture; PROJECT=private; TOOLBOX=tools; "
                'python3() { printf "%s\\n" "$@" > "$TRACE"; };\n'
                + function("apply_pair")
                + "\napply_pair initial",
                {"WORK": work, "TRACE": str(trace)},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            args = trace.read_text().splitlines()
            self.assertEqual(args[args.index("--user") + 1], f"{os.getuid()}:{os.getgid()}")

    def test_cleanup_privilege_has_only_the_private_work_mount(self):
        with tempfile.TemporaryDirectory() as root:
            work = Path(root) / "work"
            work.mkdir()
            trace = Path(root) / "trace"
            result = self.run_shell(
                'TOOLBOX=tools; docker() { printf "%s\\n" "$@" > "$TRACE"; };\n'
                + function("remove_fixture_work")
                + "\nremove_fixture_work",
                {"WORK": str(work), "TRACE": str(trace)},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            args = trace.read_text().splitlines()
            self.assertEqual(args[args.index("-v") + 1], f"{work}:/fixture")
            self.assertEqual(args.count("-v"), 1)
            self.assertEqual(args[args.index("--network") + 1], "none")
            self.assertIn("--read-only", args)
            self.assertEqual(args[args.index("--cap-drop") + 1], "ALL")
            self.assertEqual(
                {args[i + 1] for i, arg in enumerate(args) if arg == "--cap-add"},
                {"DAC_OVERRIDE", "FOWNER"},
            )
            self.assertEqual(args[args.index("--security-opt") + 1], "no-new-privileges")
            self.assertEqual(args[args.index("--user") + 1], "0")
            self.assertEqual(args[-1], "find /fixture -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +")
            self.assertNotIn("--privileged", args)
            self.assertFalse(work.exists())

    def test_failed_privileged_cleanup_retains_work_and_fails(self):
        with tempfile.TemporaryDirectory() as root:
            work = Path(root) / "work"
            work.mkdir()
            result = self.run_shell(
                "TOOLBOX=tools; docker() { return 9; };\n"
                + function("remove_fixture_work")
                + "\nremove_fixture_work",
                {"WORK": str(work)},
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(work.exists())

    def test_changed_identity_waits_for_entrypoint_readiness(self):
        fragment = SCRIPT.split("apply_pair changed\n", 1)[1].split('SECOND="$(wallet_path)"', 1)[0]
        result = self.run_shell(
            "ready_done=0; ready() { ready_done=1; }; "
            'wallet_path() { [ "$ready_done" = 1 ] || return 1; echo second; };\n'
            + fragment
            + '\nSECOND="$(wallet_path)"'
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_reverted_storage_checks_wait_for_entrypoint_readiness(self):
        fragment = SCRIPT.split("apply_pair reverted\n", 1)[1].split("# A reopened wallet", 1)[0]
        result = self.run_shell(
            "ready_done=0; FIRST=first; FIRST_INODE=1; TARI_FIRST=tari; TARI_FIRST_INODE=2; "
            "ready() { ready_done=1; }; "
            'wallet_path() { [ "$ready_done" = 1 ] || return 1; echo first; }; '
            'wallet_inode() { [ "$ready_done" = 1 ] || return 1; echo 1; }; '
            'tari_path() { [ "$ready_done" = 1 ] || return 1; echo tari; }; '
            'tari_inode() { [ "$ready_done" = 1 ] || return 1; echo 2; };\n' + fragment
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
