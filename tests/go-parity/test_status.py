import errno
import json
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

import test_cli


class StatusParityTest(unittest.TestCase):
    def setUp(self):
        test_cli.CLIParityTest.setUpClass()
        self.temp = tempfile.TemporaryDirectory(dir=test_cli.CACHE_TMP)
        self.install = Path(self.temp.name)
        self.cli = self.install / "pithead"
        shutil.copy2(test_cli.SOURCE_CLI, self.cli)
        shutil.copy2(test_cli.ROOT / "VERSION", self.install / "VERSION")
        self.bin = self.install / "bin"
        self.bin.mkdir()
        fixture = (test_cli.ROOT / "tests/go-parity/status_fixture.py").read_text()
        for name in ("docker", "podman", "curl", "openssl"):
            path = self.bin / name
            path.write_text("#!/usr/bin/env python3\n" + fixture)
            path.chmod(0o755)
        (self.bin / "sleep").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "sleep").chmod(0o755)
        self.model = self.install / "model.json"
        self.counter = self.install / "counter"
        self.env = {
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "STATUS_FIXTURE": str(self.model),
            "STATUS_COUNTER": str(self.counter),
            "PITHEAD_MIGRATION_MARKER_FILE": str(self.install / "migration"),
            "PITHEAD_CMDLINE": str(self.install / "cmdline"),
        }
        (self.install / "cmdline").write_text("rauc.slot=A\n")

    def tearDown(self):
        self.temp.cleanup()

    def compare(self, model, env_text="COMPOSE_PROFILES=local_node,local_tari\n"):
        self.model.write_text(json.dumps(model))
        (self.install / ".env").write_text(env_text)
        results = []
        for implementation in ("bash", "go"):
            self.counter.unlink(missing_ok=True)
            results.append(
                test_cli.CLIParityTest.invoke(self, implementation, "status", env=self.env)
            )
        baseline, go = results
        self.assertEqual(
            (go.returncode, go.stdout, go.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        return go

    child_environment = test_cli.CLIParityTest.child_environment

    def test_service_verdicts(self):
        for state in (
            "running:healthy",
            "running:none",
            "running:starting",
            "running:unhealthy",
            "exited:none",
            "missing",
            "restarting:none",
            "paused:none",
        ):
            with self.subTest(state=state):
                self.compare({"services": {"caddy": state}})

    def test_profiles_and_miner_holds(self):
        for node in ("running:healthy", "exited:none", "missing"):
            for syncing in (True, False, None):
                with self.subTest(node=node, syncing=syncing):
                    self.compare(
                        {
                            "services": {
                                "monerod": node,
                                "p2pool": "exited:none",
                                "xmrig-proxy": "created:none",
                            },
                            "dashboard": {"syncing": syncing},
                        }
                    )
        self.compare(
            {"services": {"monerod": "missing", "tari": "missing", "caddy": "running:none"}},
            "COMPOSE_PROFILES=\n",
        )

    def test_restart_observation(self):
        self.compare({"restart": "caddy"})
        self.compare({"bad_snapshot": True})
        self.env["PITHEAD_ENGINE"] = "podman"
        self.compare({"restart": "caddy"})

    def test_migration_hold(self):
        version = (self.install / "VERSION").read_text().strip()
        for marker in (version, version + "|A", version + "|B", "malformed", "9.9.9|A"):
            with self.subTest(marker=marker):
                (self.install / "migration").write_text(marker)
                self.compare(
                    {
                        "services": {
                            "monerod": "exited:none",
                            "tari": "missing",
                            "wallet-rpc": "created:none",
                        }
                    }
                )

    def test_chain_health_and_sync_progress(self):
        for level in ("green", "amber", "red", "unknown"):
            with self.subTest(level=level):
                self.compare(
                    {
                        "dashboard": {
                            "monero": {
                                "health": {
                                    "level": level,
                                    "reasons": ["fixture reason"],
                                    "advice": "fixture advice",
                                }
                            },
                            "tari": {"health": {"level": level, "reasons": [], "advice": "wait"}},
                        }
                    }
                )
        dashboard = {
            "syncing": True,
            "sync": {
                "monero": {
                    "state": "syncing",
                    "percent": 12.5,
                    "current": 125,
                    "target": 1000,
                    "remaining": 875,
                },
                "tari": {"state": "loading"},
            },
        }
        self.compare({"dashboard": dashboard})
        self.compare({"dashboard": dashboard}, "TARI_REQUIRED=false\n")
        self.compare({"dashboard": dashboard, "curl_exit": 1})

    def test_announcements(self):
        self.compare(
            {},
            'DASHBOARD_ONION_ENABLED=true\nDASHBOARD_ONION_ADDRESS=fixture.onion\nDASHBOARD_ONION_CLIENT_AUTH=true\nPROXY_STRATUM_PASSWORD="literal$$value\\tvalue"\n',
        )
        for secret in (r"fixture\c", r"fixture\x41", r"fixture\u0041"):
            self.compare({}, "PROXY_STRATUM_PASSWORD=" + secret + "\n")
        tls = self.install / "tls"
        tls.mkdir()
        (tls / "cert.pem").write_text("fixture certificate")
        self.compare({}, "PROXY_STRATUM_TLS=true\nPROXY_TLS_DIR=tls\n")

    def test_clearnet_banner(self):
        for flags in (
            "MONERO_CLEARNET_SYNC=true\n",
            "TARI_CLEARNET_SYNC=true\n",
            "MONERO_CLEARNET_SYNC=true\nTARI_CLEARNET_SYNC=true\n",
        ):
            self.compare({}, flags)

    def test_terminal_colors(self):
        self.model.write_text(json.dumps({"services": {"caddy": "running:unhealthy"}}))
        (self.install / ".env").write_text("MONERO_CLEARNET_SYNC=true\n")
        results = []
        for implementation in ("bash", "go"):
            self.counter.unlink(missing_ok=True)
            master, slave = os.openpty()
            env = self.child_environment(implementation, {**self.env, "NO_COLOR": ""})
            process = subprocess.Popen(  # noqa: S603
                [str(self.cli), "status"],
                cwd=self.install,
                env=env,
                stdout=slave,
                stderr=subprocess.PIPE,
                shell=False,
            )
            os.close(slave)
            stdout = bytearray()
            read_errors = []

            def drain_terminal(fd, captured, failures):
                while True:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            failures.append(error)
                        return
                    if not chunk:
                        return
                    captured.extend(chunk)

            reader = threading.Thread(
                target=drain_terminal, args=(master, stdout, read_errors), daemon=True
            )
            reader.start()
            try:
                _, stderr = process.communicate(timeout=30)
                reader.join(timeout=30)
                self.assertFalse(reader.is_alive(), "terminal reader did not finish")
                if read_errors:
                    raise read_errors[0]
            finally:
                os.close(master)
                if process.poll() is None:
                    process.kill()
                    process.communicate()
            results.append((process.returncode, bytes(stdout), stderr))
        self.assertEqual(results[0], results[1])
        self.assertIn(b"\x1b[1;33m", results[1][1])

    def test_status_is_native(self):
        self.compare({})
        bash = self.bin / "bash"
        bash.write_text("#!/bin/sh\necho unexpected-bash-fallback >&2\nexit 91\n")
        bash.chmod(0o755)
        env = test_cli.CLIParityTest.child_environment(self, "go", self.env)
        result = subprocess.run(  # noqa: S603
            [test_cli.REAL_BASH, str(self.cli), "status"],
            cwd=self.install,
            env=env,
            capture_output=True,
            timeout=30,
            shell=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"All expected services are up.", result.stdout)


if __name__ == "__main__":
    unittest.main()
