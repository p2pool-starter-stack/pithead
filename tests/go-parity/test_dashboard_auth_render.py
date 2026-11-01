import copy
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests/stack/fixtures/config-2.0.0"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

SYNTHETIC_HASH = "c3ludGhldGljLWNhY2hlZC1oYXNo"


class DashboardAuthRenderParityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.base_config = json.loads((FIXTURES / "absent.json").read_text())
        self.tools = self.directory / "bin"
        self.tools.mkdir()
        docker = self.tools / "docker"
        docker.write_text('#!/bin/sh\nprintf called >"$DOCKER_MARKER"\nexit 91\n')
        docker.chmod(0o755)

    def environment(self, implementation, binary, log, marker):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            PITHEAD_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary),
            AUTH_REAL_GO=str(GO_BINARY),
            AUTH_SPY_LOG=str(log),
            DOCKER_MARKER=str(marker),
            PATH=str(self.tools) + os.pathsep + env.get("PATH", os.defpath),
        )
        return env

    def spy(self, name):
        path = self.directory / name
        path.write_text(
            "#!/usr/bin/env bash\nset -Eeuo pipefail\n"
            'if "$AUTH_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'if [ "${PITHEAD_GO_HELPER:-}" = config-dashboard-auth ]; then\n'
            '  printf "%s:%s:%s\\n" "$PITHEAD_GO_HELPER" "${1:-}" "$rc" '
            '>>"$AUTH_SPY_LOG"\n'
            "fi\n"
            'exit "$rc"\n'
        )
        path.chmod(0o755)
        return path

    def invoke(self, implementation, name, config, platform, password, binary):
        install = self.directory / f"{name}-{implementation}"
        install.mkdir()
        fixture = install / "fixture.json"
        fixture.write_text(json.dumps(config))
        fingerprint = hashlib.sha256(password.encode()).hexdigest()
        env_file = install / ".env"
        env_file.write_text(
            f"DASHBOARD_AUTH_PW_FP={fingerprint}\nDASHBOARD_AUTH_HASH_B64={SYNTHETIC_HASH}\n"
        )
        env_file.chmod(0o600)
        log = install / "helper.log"
        marker = install / "docker-called"
        result = subprocess.run(  # noqa: S603
            [
                BASH,
                str(FIXTURES / "render.sh"),
                str(ROOT / "pithead"),
                str(fixture),
                platform,
                "platform-defaults" if platform == "1" else "",
            ],
            cwd=install,
            env=self.environment(implementation, binary, log, marker),
            capture_output=True,
            check=False,
            timeout=30,
        )

        def normalize(data):
            return data.replace(str(install).encode(), b"@ROOT@")

        files = {}
        for relative in (
            ".env",
            "config.json",
            "dashboard-host.txt",
            "local-miner.txt",
            "data/tari-wallet-secret.env",
        ):
            path = install / relative
            files[relative] = (
                normalize(path.read_bytes()),
                stat.S_IMODE(path.stat().st_mode),
            )
        return {
            "process": (result.returncode, normalize(result.stdout), normalize(result.stderr)),
            "files": files,
            "log": log.read_text() if log.exists() else "",
            "docker_called": marker.exists(),
        }

    def test_complete_render_uses_cached_auth_without_docker(self):
        cases = {
            "password-off": ("", {}),
            "lan-auth": (
                "valid LAN passphrase",
                {"auth": {"username": "operator", "password": "valid LAN passphrase"}},
            ),
            "onion-control": (
                "correct horse battery staple",
                {
                    "auth": {
                        "username": "admin",
                        "password": "correct horse battery staple",
                    },
                    "onion": {"enabled": True, "client_auth": True},
                    "control": {"enabled": True},
                },
            ),
        }
        for platform in ("0", "1"):
            for name, (password, dashboard) in cases.items():
                with self.subTest(platform=platform, case=name):
                    config = copy.deepcopy(self.base_config)
                    config.setdefault("dashboard", {}).update(dashboard)
                    spy = self.spy(f"{platform}-{name}-spy")
                    baseline = self.invoke(
                        "bash", f"{platform}-{name}", config, platform, password, GO_BINARY
                    )
                    selected = self.invoke(
                        "go", f"{platform}-{name}", config, platform, password, spy
                    )
                    self.assertEqual(selected["process"], baseline["process"])
                    self.assertEqual(selected["files"], baseline["files"])
                    self.assertEqual(selected["process"][0], 0)
                    self.assertFalse(baseline["docker_called"])
                    self.assertFalse(selected["docker_called"])
                    self.assertEqual(selected["files"][".env"][1], 0o600)
                    self.assertEqual(selected["files"]["data/tari-wallet-secret.env"][1], 0o600)
                    self.assertEqual(selected["files"][".env"][0].count(b"\n"), 133)
                    self.assertEqual(
                        selected["log"].splitlines(),
                        [
                            "config-dashboard-auth:settings:0",
                            "config-dashboard-auth:policy:0",
                        ],
                    )
                    if password:
                        encoded = password.encode()
                        self.assertNotIn(encoded, selected["files"][".env"][0])
                        self.assertNotIn(password, selected["log"])
                        self.assertNotIn(encoded, selected["process"][1])
                        self.assertNotIn(encoded, selected["process"][2])
                        self.assertIn(encoded, selected["files"]["config.json"][0])
                        self.assertIn(SYNTHETIC_HASH.encode(), selected["files"][".env"][0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
