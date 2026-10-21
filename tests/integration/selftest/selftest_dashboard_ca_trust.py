import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "lib/dashboard_ca_trust.py"
spec = importlib.util.spec_from_file_location("ca_trust", SOURCE)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

CERTIFICATE = "-----BEGIN CERTIFICATE-----\npublic-fixture\n-----END CERTIFICATE-----\n"


class ExportChecks(unittest.TestCase):
    def test_documented_command_exports_only_the_public_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            docker = root / "docker"
            docker.write_text(
                '#!/bin/sh\n[ "$*" = "compose exec -T caddy cat '
                + probe.CA_PATH
                + '" ] || exit 9\n'
                'printf "%s" "$PUBLIC_CA_FIXTURE"\n'
            )
            docker.chmod(0o700)
            with patch.dict(
                os.environ,
                {
                    "PATH": directory + os.pathsep + os.environ["PATH"],
                    "PUBLIC_CA_FIXTURE": CERTIFICATE,
                },
            ):
                identity = probe.export_ca(directory)
            self.assertEqual((root / probe.CA_FILE).read_text(), CERTIFICATE)
            self.assertEqual(len(identity), 32)

    def test_missing_export_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "public root"):
            probe.documented_export("no export command")

    def test_private_keys_and_extra_shell_commands_are_rejected(self):
        for command in (
            probe.EXPORT.replace("root.crt", "root.key"),
            probe.EXPORT + "; echo extra",
        ):
            with self.subTest(command=command), self.assertRaises(RuntimeError):
                probe.documented_export(f"```bash\n{command}\n```")

    def test_leaf_rotation_always_recovers_caddy(self):
        calls = []

        def fail_delete(args, **_kwargs):
            calls.append(args)
            if "run" in args:
                raise RuntimeError("injected leaf deletion failure")

        with patch.object(probe, "run", fail_delete), self.assertRaises(RuntimeError):
            probe.rotate_leaf()
        self.assertEqual(calls[-1], ["docker", "compose", "up", "-d", "--no-deps", "caddy"])


if __name__ == "__main__":
    unittest.main()
