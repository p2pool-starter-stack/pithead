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
    def test_registration(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)

            def write(name, text):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)

            write(
                "Makefile",
                "local-only:\n\tbash tests/test-local.sh\nci:\n\tbash tests/selftest*.sh\n",
            )
            write(".github/workflows/test.yml", "run: make ci\n")
            for name in (
                "tests/test-local.sh",
                "tests/test-shell.sh",
                "tests/test_python.py",
                "dashboard/tests/frontend/new.test.mjs",
                "tests/selftest-fixture.sh",
            ):
                write(name, "exit 0\n")
            expected = {
                "tests/test-local.sh",
                "tests/test-shell.sh",
                "tests/test_python.py",
                "dashboard/tests/frontend/new.test.mjs",
            }
            self.assertEqual(set(AUDIT.audit(root)), expected)
            write(
                ".github/workflows/test.yml",
                "run: make ci\nrun: source tests/test-shell.sh\nrun: echo bash tests/test_python.py\n# run: bash tests/test-local.sh\n",
            )
            self.assertEqual(set(AUDIT.audit(root)), expected)
            write(
                ".github/workflows/test.yml",
                "run: make ci local-only\nrun: bash tests/test-shell.sh\nrun: python3 tests/test_python.py\nrun: node --test dashboard/tests/frontend/new.test.mjs\n",
            )
            self.assertEqual(AUDIT.audit(root), [])
            write("tests/registration-allowlist.tsv", "absent.sh\tcaller.sh\treason\n")
            with self.assertRaises(ValueError):
                AUDIT.audit(root)


if __name__ == "__main__":
    unittest.main()
