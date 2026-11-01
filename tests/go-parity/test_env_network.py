import copy
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/env_network_reference.sh"
FIXTURES = ROOT / "tests/stack/fixtures/config-2.0.0"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

VIEW_KEY = "01" + "00" * 31
MONERO_WALLET = "44yQXfkWZNmJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmJ7suhUXwdrDJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmCYrSgjJ"
TARI_WALLET = (
    "12M2aZjsSvTTcaFyzLxARkvwdxv8UHJeJBA6E1pEoP967ydCL8tv17vktNDHhqDgFg5LxtHrp9Wsd1cuhyW1p6fzimM"
)
TARI_SPEND_KEY = "e2f2ae0a6abc4e71a884a961c500515f58e30b6aa582dd8db6a65945e08d2d76"


class EnvNetworkParityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.base_config = json.loads((FIXTURES / "absent.json").read_text())

    def environment(self, implementation, binary=None, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(PITHEAD_IMPL=implementation, PITHEAD_GO_BINARY=str(binary or GO_BINARY))
        env.update(extra or {})
        return env

    def make_spy(self, name, body):
        path = self.directory / name
        path.write_text("#!/usr/bin/env bash\nset -Eeuo pipefail\n" + body)
        path.chmod(0o755)
        return path

    def forwarding_spy(self, name, log):
        return self.make_spy(
            name,
            'if "$NETWORK_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "$#" "$rc" '
            '>>"$NETWORK_SPY_LOG"\nexit "$rc"\n',
        )

    def invoke(self, implementation, name, config, binary=None, extra=None, cores=None):
        install = self.directory / f"{name}-{implementation}"
        install.mkdir()
        config_file = install / "fixture.json"
        if isinstance(config, str):
            config_file.write_text(config)
        else:
            config_file.write_text(json.dumps(config))
        command = [
            BASH,
            str(FIXTURES / "render.sh" if cores is None else ADAPTER),
            str(ROOT / "pithead") if cores is None else str(ROOT),
            str(config_file),
            "0",
        ]
        if cores is not None:
            command.append(str(cores))
        result = subprocess.run(  # noqa: S603
            command,
            cwd=install,
            env=self.environment(implementation, binary, extra),
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

    def helper(self, payload, args=()):
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY), *args],
            env={**os.environ, "PITHEAD_GO_HELPER": "config-env-network"},
            input=payload,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def frame(self, raw, status=b"0", globals_=None):
        values = globals_ or [
            b"local",
            b"local",
            b"172.28.0",
            b"",
            b"",
            b"",
            b"",
            b"",
            b"false",
            b"false",
        ]
        return b"\0".join([*values, raw, status]) + b"\0"

    def assert_fixture_parity(self, name, config, expected_status=0, cores=None):
        log = self.directory / f"{name}.log"
        spy = self.forwarding_spy(f"{name}-spy", log)
        baseline = self.invoke("bash", name, config, cores=cores)
        selected = self.invoke(
            "go",
            name,
            config,
            spy,
            {"NETWORK_REAL_GO": str(GO_BINARY), "NETWORK_SPY_LOG": str(log)},
            cores,
        )
        self.assertEqual(selected, baseline)
        entries = log.read_text().splitlines()
        count = 2 if cores is not None else 1
        self.assertEqual(entries.count(f"config-env-network:0:{expected_status}"), count)
        self.assertNotIn(
            config["monero"]["node_password"]
            if isinstance(config, dict)
            else "fixture-rpc-password",
            log.read_text(),
        )
        if baseline["env"] is not None:
            self.assertEqual(baseline["env_mode"], 0o600)
        if baseline["secret"] is not None:
            self.assertEqual(baseline["secret_mode"], 0o600)
        return baseline, entries

    def test_private_protocol_returns_the_exact_network_plan(self):
        raw = (FIXTURES / "absent.json").read_bytes()
        result = self.helper(self.frame(raw))
        socks = b"--socks5 172.28.0.25:9050 --socks5-proxy-type tor --no-dns"
        expected = [
            b"172.28.0.26",
            b"18081",
            b"18083",
            b"http://127.0.0.1:18081",
            b"local_node,local_tari",
            b"172.28.0.27:18142",
            b"local_node,local_tari",
            b"127.0.0.1",
            b"1",
            b"false",
            b"false",
            b"6",
            b"48",
            b"127.0.0.1",
            b"127.0.0.1",
            b"mini",
            b"--mini " + socks,
            b"37888",
            socks,
        ]
        self.assertEqual(
            (result.returncode, result.stdout, result.stderr),
            (0, b"\0".join(expected) + b"\0", b""),
        )

    def test_private_protocol_refuses_malformed_frames_silently(self):
        raw = (FIXTURES / "absent.json").read_bytes()
        valid = self.frame(raw)
        cases = {
            "empty": b"",
            "missing-footer": b"\0".join(valid.split(b"\0")[:-3]) + b"\0",
            "failed-producer": self.frame(raw, b"19"),
            "extra-field": valid + b"extra\0",
            "bad-json": self.frame(b"{"),
            "unterminated": valid[:-1],
        }
        for name, payload in cases.items():
            with self.subTest(case=name):
                result = self.helper(payload)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))
        result = self.helper(valid, ("unexpected",))
        self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))

    def test_fixture_modes_addresses_profiles_lan_prune_and_pools_match(self):
        remote = copy.deepcopy(self.base_config)
        remote["monero"].update(
            mode="remote",
            remote={"host": "2001:db8::10", "rpc_port": 28081, "zmq_port": 28083},
        )
        remote["tari"].update(mode="remote", remote={"host": "2001:db8::20", "grpc_port": 28142})
        remote["p2pool"] = {"pool": "main", "clearnet": True}

        off = copy.deepcopy(self.base_config)
        off["tari"].update(mode="off", grpc_lan_access=True, clearnet_initial_sync=True)
        off["monero"].update(prune=False, rpc_lan_access=True, zmq_lan_access=True)
        off["p2pool"] = {"pool": "nano", "clearnet": False}

        strings = copy.deepcopy(self.base_config)
        strings["network"] = {"subnet": "10.33.44.0/24"}
        strings["monero"].update(
            prune="false",
            clearnet_initial_sync="YES",
            rpc_lan_access="true",
            zmq_lan_access="true",
        )
        strings["tari"].update(grpc_lan_access="true", clearnet_initial_sync="on")
        strings["p2pool"] = {"pool": "mini", "clearnet": "1"}

        profiles = copy.deepcopy(self.base_config)
        profiles["monero"].update(wallet_address=MONERO_WALLET, view_key=VIEW_KEY)
        profiles["tari"].update(
            wallet_address=TARI_WALLET, view_key=VIEW_KEY, spend_public_key=TARI_SPEND_KEY
        )

        for name, config in {
            "remote-ipv6-main": remote,
            "off-nano-lan-prune": off,
            "string-booleans-custom-network": strings,
            "payout-profiles": profiles,
        }.items():
            with self.subTest(case=name):
                self.assert_fixture_parity(name, config)

    def test_hardware_thread_limits_remain_in_the_shell(self):
        config = copy.deepcopy(self.base_config)
        del config["monero"]["prep_blocks_threads"]
        for cores, expected in (
            (2, b"MONERO_PREP_THREADS=4\n"),
            (64, b"MONERO_PREP_THREADS=8\n"),
        ):
            with self.subTest(cores=cores):
                baseline, _ = self.assert_fixture_parity(f"cores-{cores}", config, cores=cores)
                self.assertIn(expected, baseline["env"])

    def test_out_peer_failures_keep_the_reference_error(self):
        for value in (7, 1025, "eight"):
            config = copy.deepcopy(self.base_config)
            config["monero"]["out_peers"] = value
            with self.subTest(value=value):
                baseline, entries = self.assert_fixture_parity(f"out-peers-{value}", config)
                self.assertNotEqual(baseline["process"][0], 0)
                self.assertIn(
                    b"monero.out_peers must be an integer between 8 and 1024",
                    baseline["process"][2],
                )
                self.assertNotIn("config-env:0:0", entries)

    def test_unsupported_decimal_falls_back_to_bash(self):
        config = copy.deepcopy(self.base_config)
        config["monero"]["out_peers"] = 48.0
        raw = json.dumps(config).replace('"out_peers": 48.0', '"out_peers": 4.8e1')
        log = self.directory / "decimal-out-peers.log"
        spy = self.forwarding_spy("decimal-out-peers-spy", log)
        baseline = self.invoke("bash", "decimal-out-peers", raw, cores=8)
        selected = self.invoke(
            "go",
            "decimal-out-peers",
            raw,
            spy,
            {"NETWORK_REAL_GO": str(GO_BINARY), "NETWORK_SPY_LOG": str(log)},
            8,
        )
        self.assertEqual(selected, baseline)
        self.assertEqual(baseline["process"][0], 0)
        entries = log.read_text().splitlines()
        self.assertEqual(entries.count("config-env-network:0:0"), 1)
        self.assertEqual(entries.count("config-env-network:0:125"), 1)
        self.assertEqual(entries.count("config-env:0:0"), 2)

    def test_malformed_success_from_helper_falls_back_to_bash(self):
        poisoned_plan = (
            '"$NETWORK_REAL_GO" "$@" | '
            "{ IFS= read -r -d '' discarded; printf 'poison\\0'; cat; }"
        )
        cases = {
            "short": "printf 'poison\\0'",
            "trailing-bytes": poisoned_plan + "; printf '0\\0trailing'",
            "extra-field": poisoned_plan + "; printf '0\\0extra\\0'",
            "empty-field": poisoned_plan + "; printf '0\\0\\0'",
        }
        for name, output in cases.items():
            with self.subTest(case=name):
                log = self.directory / f"poison-{name}.log"
                spy = self.make_spy(
                    f"poison-{name}-spy",
                    'if [ "${PITHEAD_GO_HELPER:-}" = config-env-network ]; then\n'
                    f'  printf "config-env-network:%s:{name}\\n" "$#" '
                    '>>"$NETWORK_SPY_LOG"\n'
                    f"  {output}\n"
                    "  exit 0\n"
                    "fi\n"
                    'exec "$NETWORK_REAL_GO" "$@"\n',
                )
                baseline = self.invoke("bash", f"poison-{name}", self.base_config)
                selected = self.invoke(
                    "go",
                    f"poison-{name}",
                    self.base_config,
                    spy,
                    {"NETWORK_REAL_GO": str(GO_BINARY), "NETWORK_SPY_LOG": str(log)},
                )
                self.assertEqual(selected, baseline)
                self.assertEqual(log.read_text().splitlines(), [f"config-env-network:0:{name}"])


if __name__ == "__main__":
    unittest.main()
