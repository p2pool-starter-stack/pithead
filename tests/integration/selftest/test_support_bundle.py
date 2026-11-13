import importlib.util
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

PROBE = Path(__file__).resolve().parents[1] / "lib/check-support-bundle.py"
spec = importlib.util.spec_from_file_location("bundle_probe", PROBE)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class SupportBundleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "bundle.tar.gz"
        self.config = self.root / "config.json"
        self.env = self.root / "env"
        self.secrets = [
            "dashboard-fixture-value",
            "stratum-fixture-value",
            "telegram-fixture-value",
        ]
        self.config.write_text(json.dumps(self.config_data(self.secrets)))
        self.env.write_text(
            "PROXY_STRATUM_PASSWORD="
            + self.secrets[1]
            + "\nTELEGRAM_BOT_TOKEN="
            + self.secrets[2]
            + "\n"
        )
        self.files = {
            "bundle/host.txt": b"host facts",
            "bundle/doctor.json": b'{"checks":[{"status":"ok"}],"summary":{"ok":1}}',
            "bundle/doctor.txt": b"Diagnostics summary",
            "bundle/config.masked.json": json.dumps(
                self.config_data([{"__secret__": True}] * 3)
            ).encode(),
            "bundle/env.redacted": b"PROXY_STRATUM_PASSWORD=[redacted]\nTELEGRAM_BOT_TOKEN=[redacted]\nDASHBOARD_AUTH_HASH_B64=[redacted]\n",
            "bundle/compose-ps.txt": b"dashboard running",
            "bundle/logs/dashboard.log": b"service started",
        }

    def config_data(self, values):
        return {
            "dashboard": {"auth": {"password": values[0]}},
            "p2pool": {"stratum_password": values[1]},
            "telegram": {"enabled": False, "bot_token": values[2]},
        }

    def write_bundle(self, files=None, mode=0o600):
        with tarfile.open(self.archive, "w:gz") as archive:
            for name, value in (self.files if files is None else files).items():
                member = tarfile.TarInfo(name)
                member.size = len(value)
                archive.addfile(member, io.BytesIO(value))
        os.chmod(self.archive, mode)

    def check(self):
        probe.check_bundle(self.archive, self.config, self.env)

    def test_complete_bundle(self):
        self.write_bundle()
        self.check()

    def test_each_credential_in_every_file_is_rejected(self):
        for name in self.files:
            for secret in self.secrets:
                with self.subTest(name=name, credential=self.secrets.index(secret)):
                    self.write_bundle(self.files | {name: secret.encode()})
                    with self.assertRaises(ValueError):
                        self.check()

    def test_missing_and_empty_members_are_rejected(self):
        for name in self.files:
            for replacement in (None, b""):
                with self.subTest(name=name, replacement=replacement):
                    files = dict(self.files)
                    if replacement is None:
                        del files[name]
                    else:
                        files[name] = replacement
                    self.write_bundle(files)
                    with self.assertRaises(ValueError):
                        self.check()

    def test_credential_in_member_name_is_rejected(self):
        self.write_bundle(self.files | {"bundle/" + self.secrets[0]: b"text"})
        with self.assertRaises(ValueError):
            self.check()

    def test_insecure_mode_is_rejected(self):
        self.write_bundle(mode=0o644)
        with self.assertRaises(ValueError):
            self.check()

    def test_enabled_telegram_fixture_is_rejected(self):
        self.write_bundle()
        config = self.config_data(self.secrets)
        config["telegram"]["enabled"] = True
        self.config.write_text(json.dumps(config))
        with self.assertRaises(ValueError):
            self.check()

    def test_unarmed_fixture_is_rejected(self):
        self.write_bundle()
        for credential in range(3):
            values = self.secrets.copy()
            values[credential] = ""
            self.config.write_text(json.dumps(self.config_data(values)))
            with self.assertRaises(ValueError):
                self.check()
        self.config.write_text(json.dumps(self.config_data(self.secrets)))
        self.env.write_text("")
        with self.assertRaises(ValueError):
            self.check()

    def test_unmasked_config_and_unredacted_env_are_rejected(self):
        for name, content in (
            ("bundle/config.masked.json", json.dumps(self.config_data(["", "", ""])).encode()),
            ("bundle/env.redacted", b"PROXY_STRATUM_PASSWORD=[redacted]"),
            ("bundle/doctor.json", b'{"checks":[],"summary":{}}'),
            ("bundle/compose-ps.txt", b"container engine not reachable"),
            ("../outside", b"unexpected"),
        ):
            with self.subTest(name=name):
                self.write_bundle(self.files | {name: content})
                with self.assertRaises(ValueError):
                    self.check()

    def test_failure_output_withholds_sensitive_contents(self):
        self.write_bundle(self.files | {"bundle/doctor.txt": self.secrets[0].encode()})
        result = subprocess.run(  # noqa: S603
            [sys.executable, str(PROBE), str(self.archive), str(self.config), str(self.env)],
            capture_output=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertTrue(result.stderr)
        for secret in self.secrets:
            self.assertNotIn(secret.encode(), result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
