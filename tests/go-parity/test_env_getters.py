import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/env_render_reference.sh"
FIXTURE = ROOT / "tests/stack/fixtures/config-2.0.0/absent.json"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class EnvGetterParityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)

    def invoke(self, implementation):
        install = self.directory / implementation
        install.mkdir()
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(PITHEAD_IMPL=implementation, PITHEAD_GO_BINARY=str(GO_BINARY))
        result = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), "getters", str(FIXTURE)],
            cwd=install,
            env=env,
            capture_output=True,
            check=False,
            timeout=30,
        )
        env_file = install / ".env"
        secret_file = install / "data/tari-wallet-secret.env"

        def normalize(data):
            return data.replace(str(install).encode(), b"@ROOT@")

        return {
            "process": (result.returncode, normalize(result.stdout), normalize(result.stderr)),
            "env": normalize(env_file.read_bytes()) if env_file.exists() else None,
            "env_mode": stat.S_IMODE(env_file.stat().st_mode) if env_file.exists() else None,
            "secret": normalize(secret_file.read_bytes()) if secret_file.exists() else None,
            "secret_mode": stat.S_IMODE(secret_file.stat().st_mode)
            if secret_file.exists()
            else None,
        }

    def test_cached_getters_preserve_nested_substitution_output_and_err_traps(self):
        baseline = self.invoke("bash")
        selected = self.invoke("go")
        self.assertEqual(selected, baseline)
        self.assertEqual(baseline["process"][0], 0)
        stderr = baseline["process"][2]
        self.assertEqual(stderr.count(b"fingerprint diagnostic\n"), 1)
        self.assertEqual(stderr.count(b"TLS directory diagnostic\n"), 1)
        self.assertEqual(stderr.count(b"getter ERR trap\n"), 2)
        self.assertIn(b"STRATUM_TLS_FINGERPRINT=partial-fp\n", baseline["env"])
        self.assertIn(b"PITHEAD_TLS_DIR=partial-tls\n", baseline["env"])
        self.assertEqual(baseline["env_mode"], 0o600)
        self.assertEqual(baseline["secret_mode"], 0o600)


if __name__ == "__main__":
    unittest.main()
