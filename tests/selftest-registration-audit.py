import importlib.util
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "audit", Path(__file__).with_name("registration-audit.py")
)
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class RegistrationAudit(unittest.TestCase):
    def test_sibling_subprocess_registration(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / ".github/workflows").mkdir(parents=True)
            (root / "tests/os").mkdir(parents=True)
            (root / "Makefile").write_text("ci:\n\tbash tests/os/selftest-fetch.sh\n")
            (root / ".github/workflows/test.yml").write_text("run: make ci\n")
            child = "tests/os/test_fetch.py"
            orphan = "tests/os/test_unregistered.py"
            (root / child).write_text("pass\n")
            (root / orphan).write_text("pass\n")
            sibling = '"$(dirname "$0")/test_fetch.py"'
            for command, expected in (
                (f"python3 {sibling}\n", {orphan}),
                (f"source {sibling}\n", {child, orphan}),
                (f"echo python3 {sibling}\n", {child, orphan}),
                (f"# python3 {sibling}\n", {child, orphan}),
            ):
                with self.subTest(command=command):
                    (root / "tests/os/selftest-fetch.sh").write_text(command)
                    self.assertEqual(set(AUDIT.audit(root)), expected)

    def test_registration(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)

            def write(name, text):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)

            write(
                "Makefile",
                "local-only:\n\tbash tests/os/selftest-engine-contract.sh\nci:\n\tbash tests/integration/selftest/*.sh\n",
            )
            write(".github/workflows/test.yml", "run: make ci\n")
            for name in (
                "tests/os/selftest-engine-contract.sh",
                "tests/os/selftest-required-coverage.sh",
                "tests/selftest-registration-audit.py",
                "dashboard/tests/frontend/new.test.mjs",
                "tests/integration/selftest/selftest-harness-pregate.sh",
            ):
                write(name, "exit 0\n")
            expected = {
                "tests/os/selftest-engine-contract.sh",
                "tests/os/selftest-required-coverage.sh",
                "tests/selftest-registration-audit.py",
                "dashboard/tests/frontend/new.test.mjs",
            }
            self.assertEqual(set(AUDIT.audit(root)), expected)
            write(
                ".github/workflows/test.yml",
                "run: make ci\nrun: source tests/os/selftest-required-coverage.sh\nrun: echo bash tests/selftest-registration-audit.py\n# run: bash tests/os/selftest-engine-contract.sh\n",
            )
            self.assertEqual(set(AUDIT.audit(root)), expected)
            write(
                ".github/workflows/test.yml",
                "run: make ci local-only\nrun: bash tests/os/selftest-required-coverage.sh\nrun: python3 tests/selftest-registration-audit.py\nrun: node --test dashboard/tests/frontend/new.test.mjs\n",
            )
            self.assertEqual(AUDIT.audit(root), [])
            write("tests/registration-allowlist.tsv", "absent.sh\tcaller.sh\treason\n")
            with self.assertRaises(ValueError):
                AUDIT.audit(root)


if __name__ == "__main__":
    unittest.main()
