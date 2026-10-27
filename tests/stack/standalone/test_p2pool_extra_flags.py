import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ABSENT = object()
BASH = shutil.which("bash")


class ExtraFlagsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.config = self.directory / "config.json"
        self.live = self.directory / "live.json"
        self.config.write_text("{}")
        self.live.write_text("{}")

    def shell(self, action, **extra):
        return subprocess.run(  # noqa: S603
            [BASH, "-c", 'source "$ROOT/pithead"; ' + action],
            cwd=self.directory,
            env={
                **os.environ,
                "ROOT": str(ROOT),
                "PITHEAD_CONFIG_FILE": str(self.config),
                "PITHEAD_ENV_FILE": str(self.directory / ".env"),
                **extra,
            },
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )

    def write_flags(self, flags=ABSENT, clearnet=False, mode="local"):
        config = {
            "monero": {
                "mode": mode,
                "wallet_address": "48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoD",
                "node_username": "fixture",
                "node_password": "fixture",
            },
            "tari": {"mode": "off"},
            "p2pool": {"clearnet": clearnet},
            "dashboard": {"host": "fixture.example", "secure": False},
        }
        if flags is not ABSENT:
            config["p2pool"]["extra_flags"] = flags
        self.config.write_text(json.dumps(config))

    def test_defaults(self):
        reference = json.loads((ROOT / "config.reference.json").read_text())
        self.assertEqual(reference["p2pool"]["extra_flags"], [])
        for clearnet in (False, True):
            expected = (
                "--mini"
                if clearnet
                else "--mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor --no-dns"
            )
            for flags in (ABSENT, []):
                with self.subTest(clearnet=clearnet, flags=flags):
                    self.write_flags(flags, clearnet)
                    self.assertEqual(self.render(), expected)

    def render(self):
        result = self.shell("""
PITHEAD_DRY_RUN=1
parse_and_validate_config
load_preserved_state
resolve_dashboard_host
render_env "$PITHEAD_ENV_DRYRUN" >&2
env_get_file "$PITHEAD_ENV_DRYRUN" P2POOL_FLAGS
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()[-1]

    def test_render_order_and_final_arguments(self):
        executable = self.directory / "p2pool"
        executable.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        executable.chmod(0o755)
        for clearnet in (False, True):
            self.write_flags(["--loglevel 3", "--no-dns", "--out-peers 20", "--no-dns"], clearnet)
            flags = self.render()
            self.assertEqual(flags.split().count("--no-dns"), 1)
            expected = (
                "--mini --loglevel 3 --no-dns --out-peers 20"
                if clearnet
                else "--mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor --no-dns --loglevel 3 --out-peers 20"
            )
            self.assertEqual(flags, expected)
            result = subprocess.run(  # noqa: S603
                [BASH, str(ROOT / "build/p2pool/entrypoint.sh"), "--stratum", "0.0.0.0:3333"],
                env={
                    **os.environ,
                    "PATH": str(self.directory) + os.pathsep + os.environ["PATH"],
                    "P2POOL_FLAGS": flags,
                },
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines()[-len(flags.split()) :], flags.split())

    def test_absent_p2pool_block(self):
        result = self.shell("validate_p2pool_extra_flags")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_before_password_writeback(self):
        self.write_flags(["--wallet bad"])
        document = json.loads(self.config.read_text())
        document["dashboard"]["onion"] = {"enabled": True}
        self.config.write_text(json.dumps(document))
        original = self.config.read_bytes()
        result = self.shell("ensure_onion_password")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("p2pool.extra_flags", result.stderr)
        self.assertEqual(self.config.read_bytes(), original)

    def test_trailing_whitespace(self):
        for value in (
            "--loglevel 3\n",
            "--loglevel 3\r",
            "--out-peers 20\n",
            "--addpeers peer.example:1234\n",
        ):
            self.write_flags([value])
            result = self.shell("validate_p2pool_extra_flags")
            self.assertNotEqual(result.returncode, 0, repr(value))

    def test_allowlist_and_ranges(self):
        valid = [
            "--no-console-log",
            "--no-cache",
            "--no-color",
            "--no-randomx",
            "--full-validation",
            "--loglevel 0",
            "--loglevel 6",
            "--out-peers 10",
            "--in-peers 450",
            "--in-peers-localhost 20",
            "--p2p-external-port 65535",
            "--addpeers peer.example:37888,other.onion:37889",
            "--no-dns",
        ]
        self.write_flags(valid)
        result = self.shell("validate_p2pool_extra_flags")
        self.assertEqual(result.returncode, 0, result.stderr)
        for value in (
            None,
            {},
            "--no-dns",
            [1],
            [None],
            ["--loglevel"],
            ["--loglevel 7"],
            ["--out-peers 9"],
            ["--in-peers 451"],
            ["--p2p-external-port 0"],
            ["--p2p-external-port 65536"],
            ["--addpeers peer.example:0"],
            ["--addpeers peer.example:65536"],
            ["--addpeers --wallet"],
            ["--no-dns yes"],
            ["--unknown"],
            ["--loglevel 3 --wallet"],
        ):
            with self.subTest(value=value):
                self.write_flags(value)
                result = self.shell("validate_p2pool_extra_flags")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("p2pool.extra_flags", result.stderr)

    def test_shell_characters_rejected_without_writes(self):
        for character in (
            '"',
            "'",
            "$",
            "`",
            ";",
            "|",
            "&",
            "*",
            "?",
            "[",
            "]",
            "\\",
            "\n",
            "\r",
            "\t",
        ):
            with self.subTest(character=character):
                self.write_flags(["--addpeers peer" + character + ".example:1234"])
                original = self.config.read_bytes()
                result = self.shell("parse_and_validate_config")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("p2pool.extra_flags", result.stderr)
                self.assertEqual(self.config.read_bytes(), original)
                self.assertFalse((self.directory / ".env").exists())
                self.assertFalse((self.directory / "data").exists())

    def test_owned_flags_and_aliases(self):
        groups = {
            "p2pool.pool": ["--mini", "--nano"],
            "p2pool.clearnet": ["--socks5 proxy:9050", "--socks5-proxy-type tor"],
            "monero.wallet_address": ["--wallet wallet", "--subaddress address"],
            "monero.mode": [
                "--host node",
                "--rpc-port 18081",
                "--rpc-login user",
                "--rpc-ssl",
                "--rpc-ssl-fingerprint fingerprint",
                "--zmq-port 18083",
            ],
            "tari.mode": ["--merge-mine endpoint"],
            "Tor profile": ["--onion-address peer.onion"],
            "p2pool.stratum_bind": [
                "--stratum localhost:3333",
                "--tls-cert cert",
                "--upnp-stratum",
                "--start-mining 1",
            ],
            "network profile": ["--no-clearnet-p2p", "--no-upnp", "--no-igd"],
            "p2pool.pool and the network profile": ["--p2p localhost:37888"],
            "data API profile": ["--data-api stats", "--local-api", "--stratum-api"],
            "RAM profile": ["--light-mode"],
            "p2pool.data_dir": [
                "--data-dir data",
                "--log-file log",
                "--no-log-file",
                "--disable-log",
            ],
        }
        for owner, flags in groups.items():
            for flag in flags:
                with self.subTest(flag=flag):
                    self.write_flags([flag])
                    result = self.shell("validate_p2pool_extra_flags")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(owner, result.stderr)
        self.write_flags(["--no-randomx"], mode="remote")
        self.assertIn("monero.mode local", self.shell("validate_p2pool_extra_flags").stderr)

    def test_preview_classification(self):
        for flag, tier in (
            ("--loglevel 3", "INFO"),
            ("--out-peers 20", "INFO"),
            ("--no-dns", "CONFIRM"),
            ("--addpeers peer.example:1234", "CONFIRM"),
            ("--p2p-external-port 1234", "CONFIRM"),
        ):
            result = self.shell('describe_change P2POOL_FLAGS "--mini" "--mini $EXTRA"', EXTRA=flag)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.startswith(tier + "\t"), result.stdout)
            self.assertNotIn("PPLNS", result.stdout)
            self.assertNotIn("sidechain changing", result.stdout)
        result = self.shell(
            'describe_change P2POOL_FLAGS "--mini --no-dns" "--mini --no-dns --loglevel 3"'
        )
        self.assertTrue(result.stdout.startswith("INFO\t"), result.stdout)

    def test_clearnet_preview_honors_no_dns(self):
        self.write_flags(["--no-dns"], clearnet=True)
        result = self.shell(
            "egress_direct_for() { return 0; }; describe_change P2POOL_CLEARNET false true"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("CONFIRM\t"), result.stdout)
        self.assertIn("seed-node DNS stays disabled", result.stdout)
        self.assertNotIn("resumes clearnet seed-node DNS", result.stdout)

    def test_deduplicated_config_preview(self):
        self.live.write_text('{"p2pool":{"extra_flags":[]}}')
        self.write_flags(["--no-dns"])
        result = self.shell(
            'control_mark_config_confirm_rows p2pool.extra_flags "" "$STAGED"',
            PITHEAD_CONFIG_FILE=str(self.live),
            STAGED=str(self.config),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CONFIRM\tp2pool.extra_flags\tP2Pool expert options:", result.stdout)
        self.assertIn("--no-dns", result.stdout)


if __name__ == "__main__":
    unittest.main()
