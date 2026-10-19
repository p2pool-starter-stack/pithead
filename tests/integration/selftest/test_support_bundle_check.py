import importlib.util
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "bundle_check", Path(__file__).resolve().parents[1] / "lib/support-bundle-check.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BundleCheckTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.archive = Path(self.temp.name) / "bundle.tar.gz"
        self.secrets = ["Dashboard-Fixture-42", "Stratum-Fixture-42", "123456:BotFixture42"]
        masked = {"__secret__": True}
        self.files = {
            "bundle/host.txt": b"host diagnostics",
            "bundle/doctor.txt": b"Diagnostics summary",
            "bundle/doctor.json": json.dumps(
                {"checks": [{"status": "ok"}], "summary": {"ok": 1}}
            ).encode(),
            "bundle/config.masked.json": json.dumps(
                {
                    "dashboard": {"auth": {"password": masked}},
                    "p2pool": {"stratum_password": masked},
                    "telegram": {"bot_token": masked},
                }
            ).encode(),
            "bundle/env.redacted": b"DASHBOARD_AUTH_HASH_B64=[redacted]\nPROXY_STRATUM_PASSWORD=[redacted]\nTELEGRAM_BOT_TOKEN=[redacted]\n",
            "bundle/compose-ps.txt": b"running",
            "bundle/logs/p2pool.log": b"live p2pool log",
        }

    def write(self):
        with tarfile.open(self.archive, "w:gz") as bundle:
            for name, content in self.files.items():
                member = tarfile.TarInfo(name)
                member.size = len(content)
                bundle.addfile(member, io.BytesIO(content))
        self.archive.chmod(0o600)

    def test_complete_bundle(self):
        self.write()
        module.check_bundle(self.archive, self.secrets)

    def test_each_credential_is_found_in_any_member(self):
        for secret in self.secrets:
            with self.subTest(secret_length=len(secret)):
                self.files["bundle/logs/extra.log"] = secret.encode()
                self.write()
                with self.assertRaises(ValueError):
                    module.check_bundle(self.archive, self.secrets)

    def test_missing_members_and_empty_logs_fail(self):
        for name in list(self.files):
            with self.subTest(member=name):
                original = self.files.pop(name)
                self.write()
                with self.assertRaises((ValueError, KeyError)):
                    module.check_bundle(self.archive, self.secrets)
                self.files[name] = original

    def test_duplicate_members_cannot_hide_a_leak(self):
        self.write()
        with tarfile.open(self.archive, "w:gz") as bundle:
            entries = list(self.files.items()) + [
                ("bundle/logs/extra.log", self.secrets[0].encode()),
                ("bundle/logs/extra.log", b"clean replacement"),
            ]
            for name, content in entries:
                member = tarfile.TarInfo(name)
                member.size = len(content)
                bundle.addfile(member, io.BytesIO(content))
        with self.assertRaises(ValueError):
            module.check_bundle(self.archive, self.secrets)

    def test_world_readable_archive_fails(self):
        self.write()
        self.archive.chmod(0o644)
        with self.assertRaises(ValueError):
            module.check_bundle(self.archive, self.secrets)

    def test_unmasked_config_fails(self):
        self.files["bundle/config.masked.json"] = b'{"dashboard":{"auth":{"password":"visible"}}}'
        self.write()
        with self.assertRaises(ValueError):
            module.check_bundle(self.archive, self.secrets)


if __name__ == "__main__":
    unittest.main()
