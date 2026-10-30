# ruff: noqa: S603, S607
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "proof", Path(__file__).resolve().parents[1] / "scripts/lint/rc-regression-proof.py"
)
PROOF = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROOF)


class RegressionProof(unittest.TestCase):
    def test_proof(self):
        with tempfile.TemporaryDirectory() as temp:

            def git(*args):
                return subprocess.check_output(["git", *args], cwd=temp, text=True).strip()

            git("init", "-q")
            git(
                "-c",
                "user.name=fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "commit",
                "-qm",
                "red",
                "--allow-empty",
            )
            red = git("rev-parse", "HEAD")
            git(
                "-c",
                "user.name=fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "commit",
                "-qm",
                "green",
                "--allow-empty",
            )
            head = git("rev-parse", "HEAD")
            valid = f"RC regression RED: job 1@{red}\nRC regression GREEN: job 2@{head}\n"
            PROOF.validate(valid, head, temp)
            for body in (
                "",
                valid.splitlines()[0],
                valid.replace(red, head),
                valid.replace("job 2", "job 1"),
                valid.replace(red, "a" * 40),
                valid.replace(head, red),
            ):
                with self.subTest(body=body), self.assertRaises(ValueError):
                    PROOF.validate(body, head, temp)

    def test_closing(self):
        for keyword in ("closes", "Closes", "fixes", "resolves"):
            self.assertEqual(PROOF.CLOSING.findall(f"{keyword} #3403"), [("", "3403")])
        self.assertFalse(PROOF.CLOSING.findall("mentions #3403"))


if __name__ == "__main__":
    unittest.main()
