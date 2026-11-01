import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = Path(os.environ.get("PITHEAD_PARITY_BASE", ROOT / ".go-cache/review-2035-base"))
BASE_HASHES = {
    "pithead": "516e7c17c55973bf7e697e15ead1c365af238a6416c969a21ebd2eaad78f5cbc",
    "VERSION": "c28fcca53637bc88e124af1725df13cb98c69dedefd62fb3cdbe1cdb6b760624",
}
CASES = (
    ("help",),
    ("-h",),
    ("--help",),
    ("version",),
    ("-V",),
    ("--version",),
    ("status", "--help"),
    ("unknown", "--literal=$DOCS_URL", "space value"),
    ("version", "help"),
    ("help", "ignored"),
)


class FrozenCLIParity(unittest.TestCase):
    def setUp(self):
        for path in (BASE / "pithead", ROOT / "pithead", ROOT / "go/bin/pithead"):
            if not path.is_file():
                raise AssertionError(f"required CLI artifact missing: {path}")
        for name, expected in BASE_HASHES.items():
            digest = hashlib.sha256((BASE / name).read_bytes()).hexdigest()
            if digest != expected:
                raise AssertionError(f"{name} differs from the generated a73ffced baseline")
        self.scratch = tempfile.TemporaryDirectory(dir=ROOT / ".go-cache")
        self.addCleanup(self.scratch.cleanup)
        self.installs = {}
        for name, source in (("base", BASE), ("candidate", ROOT)):
            install = Path(self.scratch.name) / name
            install.mkdir()
            shutil.copy2(source / "pithead", install / "pithead")
            shutil.copy2(BASE / "VERSION", install / "VERSION")
            self.installs[name] = install

    def invoke(self, name, mode, arguments):
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("PITHEAD_") and key != "BASH_ENV"
        }
        env["NO_COLOR"] = "1"
        if mode is not None:
            env["PITHEAD_IMPL"] = mode
        env["PITHEAD_GO_BINARY"] = str(ROOT / "go/bin/pithead")
        install = self.installs[name]
        result = subprocess.run(  # noqa: S603
            ["./pithead", *arguments],
            cwd=install,
            env=env,
            capture_output=True,
            check=False,
            timeout=20,
        )
        return result.returncode, result.stdout, result.stderr

    def test_public_reference_modes_match_starting_commit(self):
        for mode in (None, "bash", "python"):
            for arguments in CASES:
                with self.subTest(mode=mode, arguments=arguments):
                    self.assertEqual(
                        self.invoke("candidate", mode, arguments),
                        self.invoke("base", None, arguments),
                    )

    def test_go_matches_starting_commit(self):
        for arguments in CASES:
            with self.subTest(arguments=arguments):
                self.assertEqual(
                    self.invoke("candidate", "go", arguments),
                    self.invoke("base", None, arguments),
                )


if __name__ == "__main__":
    unittest.main()
