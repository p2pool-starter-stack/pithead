import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/network_settings_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

FIELDS = (
    "NETWORK_SUBNET",
    "NETWORK_PREFIX",
    "TOR_EGRESS_FIREWALL",
    "TOR_AUTO_HEAL",
    "TARI_EXPLORER_URL",
    "P2POOL_CLEARNET",
    "MONERO_REMOTE_HOST",
    "MONERO_REMOTE_RPC_PORT",
    "MONERO_REMOTE_ZMQ_PORT",
    "TARI_REMOTE_HOST",
    "TARI_REMOTE_GRPC_PORT",
    "POOL_TYPE",
)
DEFAULTS = (
    "172.28.0.0/24",
    "172.28.0",
    "true",
    "false",
    "https://textexplore.tari.com/?json",
    "false",
    "",
    "",
    "",
    "",
    "",
    "mini",
)
SEEDS = tuple(f"seed-{name.lower().replace('_', '-')}" for name in FIELDS)


class NetworkSettingsParityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.config = self.directory / "config.json"
        self.second = self.directory / "second.json"
        self.marker = self.directory / "jq-called"
        self.tools = self.directory / "bin"
        self.tools.mkdir()
        jq = self.tools / "jq"
        jq.write_text('#!/bin/sh\nprintf called >"$JQ_MARKER"\nexit 91\n')
        jq.chmod(0o755)

    def environment(self, implementation, binary=None, forbid_jq=False, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            NETWORK_SETTINGS_PARITY_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            JQ_MARKER=str(self.marker),
        )
        if forbid_jq:
            env["PATH"] = str(self.tools) + os.pathsep + env.get("PATH", os.defpath)
        env.update(extra or {})
        return env

    def invoke(
        self,
        implementation,
        raw,
        modes=("local", "local"),
        *,
        binary=None,
        forbid_jq=False,
        second=None,
        second_modes=("local", "local"),
        extra=None,
    ):
        self.config.write_bytes(raw)
        args = [BASH, str(ADAPTER), str(ROOT), str(self.config), *modes]
        if second is not None:
            self.second.write_bytes(second)
            args.extend([str(self.second), *second_modes])
        self.marker.unlink(missing_ok=True)
        return subprocess.run(  # noqa: S603
            args,
            env=self.environment(implementation, binary, forbid_jq, extra),
            capture_output=True,
            check=False,
            timeout=15,
        )

    def helper(self, raw, modes=("local", "local"), path=None):
        target = path or self.config
        if raw is not None:
            target.write_bytes(raw)
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env["PITHEAD_GO_HELPER"] = "config-network-settings"
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY), str(target), *modes],
            env=env,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def encoded(self, document):
        return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()

    def result(self, completed):
        return completed.returncode, completed.stdout, completed.stderr

    def state(self, completed):
        values = completed.stdout.split(b"\0")
        self.assertEqual(len(values), 14)
        self.assertEqual((values[0], values[-1]), (b"", b""))
        return tuple(value.decode() for value in values[1:-1])

    def test_supported_successes_match_reference_without_jq(self):
        cases = [
            ({}, ("local", "local"), DEFAULTS),
            (
                {
                    "network": {"subnet": False, "tor_egress_firewall": False},
                    "tor": {"auto_heal": None},
                    "tari": {"explorer_url": False},
                    "p2pool": {"clearnet": None, "pool": False},
                },
                ("local", "local"),
                (*DEFAULTS[:2], "false", *DEFAULTS[3:]),
            ),
            (
                {
                    "network": {"subnet": "10.20.30.0/24", "tor_egress_firewall": False},
                    "tor": {"auto_heal": True},
                    "tari": {"explorer_url": "https://explore.example/?a=1"},
                    "p2pool": {"clearnet": True, "pool": "main"},
                },
                ("local", "off"),
                (
                    "10.20.30.0/24",
                    "10.20.30",
                    "false",
                    "true",
                    "https://explore.example/?a=1",
                    "true",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "main",
                ),
            ),
            (
                {
                    "monero": {
                        "remote": {"host": "node_1.example", "rpc_port": 18082, "zmq_port": 18084}
                    },
                    "tari": {"remote": {"host": "2001:db8::5", "grpc_port": 18143}},
                    "p2pool": {"pool": "nano"},
                },
                ("remote", "remote"),
                (*DEFAULTS[:6], "node_1.example", "18082", "18084", "2001:db8::5", "18143", "nano"),
            ),
        ]
        for index, (document, modes, expected) in enumerate(cases):
            raw = self.encoded(document)
            with self.subTest(index=index):
                baseline = self.invoke("bash", raw, modes)
                selected = self.invoke("go", raw, modes, forbid_jq=True)
                self.assertEqual(self.result(selected), self.result(baseline))
                self.assertEqual(selected.returncode, 0)
                self.assertEqual(self.state(selected), expected)
                self.assertFalse(self.marker.exists())

    def test_supported_errors_preserve_reference_partial_state(self):
        base = DEFAULTS[:6]
        cases = [
            (
                {"network": {"subnet": "10.20.30.0/16"}},
                ("local", "local"),
                ("10.20.30.0/16", *SEEDS[1:]),
                "network.subnet",
            ),
            (
                {"network": {"subnet": "999.20.30.0/24"}},
                ("local", "local"),
                ("999.20.30.0/24", "999.20.30", *SEEDS[2:]),
                "network.subnet",
            ),
            ({}, ("remote", "local"), (*base, "", "", "", "", "", SEEDS[11]), "monero.remote.host"),
            (
                {"monero": {"remote": {"host": "node.example", "rpc_port": "018081"}}},
                ("remote", "local"),
                (*base, "node.example", "018081", "", "", "", SEEDS[11]),
                "monero.remote.rpc_port",
            ),
            (
                {
                    "monero": {"remote": {"host": "bad host", "rpc_port": 0}},
                    "tari": {"remote": {"host": "bad,tari"}},
                },
                ("remote", "remote"),
                (*base, "bad host", "", "", "", "", SEEDS[11]),
                "monero.remote.host",
            ),
            (
                {"tari": {"remote": {"host": "tari.example", "grpc_port": "018142"}}},
                ("local", "remote"),
                (*base, "", "", "", "tari.example", "018142", SEEDS[11]),
                "tari.remote.grpc_port",
            ),
            (
                {"p2pool": {"pool": "other"}},
                ("local", "local"),
                (*DEFAULTS[:-1], "other"),
                "p2pool.pool",
            ),
        ]
        for index, (document, modes, expected, reason) in enumerate(cases):
            raw = self.encoded(document)
            with self.subTest(index=index):
                baseline = self.invoke("bash", raw, modes)
                selected = self.invoke("go", raw, modes, forbid_jq=True)
                self.assertEqual(self.result(selected), self.result(baseline))
                self.assertEqual(selected.returncode, 1)
                self.assertIn(reason.encode(), selected.stderr)
                self.assertEqual(self.state(selected), expected)
                self.assertFalse(self.marker.exists())

    def test_repeat_parse_clears_remote_globals(self):
        first = self.encoded(
            {
                "monero": {"remote": {"host": "monero.example"}},
                "tari": {"remote": {"host": "tari.example"}},
            }
        )
        second = self.encoded({"p2pool": {"pool": "main"}})
        baseline = self.invoke(
            "bash", first, ("remote", "remote"), second=second, second_modes=("local", "off")
        )
        selected = self.invoke(
            "go",
            first,
            ("remote", "remote"),
            second=second,
            second_modes=("local", "off"),
            forbid_jq=True,
        )
        self.assertEqual(self.result(selected), self.result(baseline))
        self.assertEqual(self.state(selected), (*DEFAULTS[:-1], "main"))
        self.assertFalse(self.marker.exists())

    def test_unsupported_documents_fall_back_byte_for_byte(self):
        cases = [
            (b'{"network":{"subnet":123.0}}', ("local", "local")),
            (b'{"network":{"tor_egress_firewall":[]}}', ("local", "local")),
            (b'{"tari":{"explorer_url":{"url":"x"}}}', ("local", "local")),
            (b'{"monero":{"remote":{"host":"line\\u0001break"}}}', ("remote", "local")),
            (b'{"monero":{"remote":{"host":"node","rpc_port":18081.0}}}', ("remote", "local")),
            (b'{"tari":{"remote":{"host":["node"]}}}', ("local", "remote")),
            (b'{"p2pool":{"pool":"mini","pool":"main"}}', ("local", "local")),
            (b'{"network":{},"network":{"subnet":"10.0.0.0/24"}}', ("local", "local")),
            (b"[]", ("local", "local")),
            (b"1", ("local", "local")),
            (b"{", ("local", "local")),
        ]
        for raw, modes in cases:
            with self.subTest(raw=raw):
                baseline = self.invoke("bash", raw, modes)
                selected = self.invoke("go", raw, modes)
                self.assertEqual(self.result(selected), self.result(baseline))
                self.assertEqual(self.result(self.helper(raw, modes)), (125, b"", b""))

    def make_helper(self, name, output, status):
        path = self.directory / name
        path.write_text(
            "#!/usr/bin/env bash\n"
            "set -Eeuo pipefail\n"
            'printf "%s:%s:%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "$#" "${1:-}" '
            '"${2:-}" "${3:-}" >>"$NETWORK_SETTINGS_HELPER_LOG"\n'
            f"printf '{output}'\n"
            f"exit {status}\n"
        )
        path.chmod(0o755)
        return path

    def test_refused_and_malformed_helpers_fall_back_without_poison(self):
        poison = ["poison"] * 12
        frame = r"12\0" + r"\0".join(poison) + r"\0\0"
        helpers = [
            self.make_helper("refused", frame, 125),
            self.make_helper("extra", frame + r"extra\0", 0),
        ]
        log = self.directory / "helper.log"
        raw = self.encoded({"network": {"subnet": "10.20.30.0/24"}})
        baseline = self.invoke("bash", raw)
        missing_hook = self.invoke("go", raw, extra={"NETWORK_SETTINGS_WITHOUT_GO_HOOK": "1"})
        self.assertEqual(self.result(missing_hook), self.result(baseline))
        for helper in helpers:
            with self.subTest(helper=helper.name):
                selected = self.invoke(
                    "go",
                    raw,
                    binary=helper,
                    extra={"NETWORK_SETTINGS_HELPER_LOG": str(log)},
                )
                self.assertEqual(self.result(selected), self.result(baseline))
                self.assertNotIn(b"poison", selected.stdout)
        calls = log.read_text().splitlines()
        self.assertEqual(len(calls), len(helpers))
        self.assertTrue(all(line.startswith("config-network-settings:3:") for line in calls))

    def test_private_helper_frames(self):
        cases = [
            ({}, ("local", "local"), "12", ""),
            ({"network": {"subnet": "bad"}}, ("local", "local"), "1", "network.subnet"),
            ({"network": {"subnet": "999.1.2.0/24"}}, ("local", "local"), "2", "network.subnet"),
            ({}, ("remote", "local"), "11", "monero.remote.host"),
        ]
        for document, modes, assigned, reason in cases:
            with self.subTest(assigned=assigned):
                result = self.helper(self.encoded(document), modes)
                self.assertEqual((result.returncode, result.stderr), (0, b""))
                fields = result.stdout.split(b"\0")
                self.assertEqual(len(fields), 15)
                self.assertEqual(fields[0], assigned.encode())
                self.assertEqual(fields[-1], b"")
                if reason:
                    self.assertIn(reason.encode(), fields[-2])
                else:
                    self.assertEqual(fields[-2], b"")


if __name__ == "__main__":
    unittest.main()
