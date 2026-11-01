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
ADAPTER = ROOT / "tests/go-parity/env_memory_reference.sh"
FIXTURES = ROOT / "tests/stack/fixtures/config-2.0.0"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class EnvMemoryParityTests(unittest.TestCase):
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

    def forwarding_spy(self, name):
        return self.make_spy(
            name,
            'if "$MEMORY_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'if [ "${PITHEAD_GO_HELPER:-}" = config-env-memory ]; then '
            'printf "%s:%s:%s:%s\\n" "$PITHEAD_GO_HELPER" "${1:-}" "$#" "$rc" '
            '>>"$MEMORY_SPY_LOG"; fi\nexit "$rc"\n',
        )

    def invoke(
        self,
        implementation,
        name,
        config,
        memory_limit=None,
        ram="16384",
        huge="6144",
        binary=None,
        extra=None,
    ):
        install = self.directory / f"{name}-{implementation}"
        install.mkdir()
        config_file = install / "fixture.json"
        if isinstance(config, str):
            config_file.write_text(config)
        else:
            config_file.write_text(json.dumps(config))
        hardware_log = install / "hardware.log"
        if memory_limit is None:
            command = [
                BASH,
                str(FIXTURES / "render.sh"),
                str(ROOT / "pithead"),
                str(config_file),
                "0",
            ]
        else:
            command = [
                BASH,
                str(ADAPTER),
                str(ROOT),
                str(config_file),
                "0",
                memory_limit,
                ram,
                huge,
                str(hardware_log),
            ]
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
            "hardware": hardware_log.read_text().splitlines() if hardware_log.exists() else [],
        }

    def helper(self, operation, payload, args=()):
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY), operation, *args],
            env={**os.environ, "PITHEAD_GO_HELPER": "config-env-memory"},
            input=payload,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def settings_frame(self, mode, raw, status=b"0"):
        return b"\0".join((mode.encode(), raw, status)) + b"\0"

    def limit_frame(self, ram, huge):
        return b"\0".join((ram.encode(), huge.encode())) + b"\0"

    def assert_parity(
        self,
        name,
        config,
        memory_limit=None,
        ram="16384",
        huge="6144",
        statuses=(),
    ):
        log = self.directory / f"{name}.log"
        spy = self.forwarding_spy(f"{name}-spy")
        baseline = self.invoke("bash", name, config, memory_limit, ram, huge)
        selected = self.invoke(
            "go",
            name,
            config,
            memory_limit,
            ram,
            huge,
            spy,
            {"MEMORY_REAL_GO": str(GO_BINARY), "MEMORY_SPY_LOG": str(log)},
        )
        self.assertEqual(selected, baseline)
        entries = log.read_text().splitlines()
        for entry, count in statuses:
            self.assertEqual(entries.count(entry), count)
        self.assertEqual(baseline["process"][0], 0)
        self.assertEqual(baseline["env_mode"], 0o600)
        self.assertEqual(baseline["secret_mode"], 0o600)
        return baseline, entries

    def test_private_settings_limit_and_malformed_frames(self):
        raw = (FIXTURES / "absent.json").read_bytes()
        settings = self.helper("settings", self.settings_frame("local", raw))
        self.assertEqual(
            (settings.returncode, settings.stdout, settings.stderr),
            (0, b"8g\x004g\x00", b""),
        )
        limits = {
            ("16384", "6144"): b"7680m\0",
            ("32768", "6144"): b"19968m\0",
            ("1024", "0"): b"2048m\0",
            ("", "-1"): b"12288m\0",
        }
        for facts, expected in limits.items():
            with self.subTest(facts=facts):
                result = self.helper("limit", self.limit_frame(*facts))
                self.assertEqual(
                    (result.returncode, result.stdout, result.stderr), (0, expected, b"")
                )
        bad = (
            ("settings", b""),
            ("settings", self.settings_frame("local", raw, b"7")),
            ("settings", self.settings_frame("local", b"{")),
            ("limit", self.limit_frame("01", "0")),
            ("limit", self.limit_frame("1.0", "0")),
            ("limit", self.limit_frame("16384", "1e3")),
            ("other", b""),
        )
        for operation, payload in bad:
            with self.subTest(operation=operation, payload=payload):
                result = self.helper(operation, payload)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))
        result = self.helper("settings", self.settings_frame("local", raw), ("extra",))
        self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))

    def test_auto_memory_formulas_and_hardware_order_match(self):
        cases = (
            ("16g-huge", "16384", "6144", b"TARI_MEM_LIMIT=7680m\n"),
            ("32g-huge", "32768", "6144", b"TARI_MEM_LIMIT=19968m\n"),
            ("low-floor", "1024", "0", b"TARI_MEM_LIMIT=2048m\n"),
        )
        statuses = (
            ("config-env-memory:settings:1:0", 2),
            ("config-env-memory:limit:1:0", 1),
        )
        for name, ram, huge, expected in cases:
            with self.subTest(case=name):
                baseline, _ = self.assert_parity(
                    name, self.base_config, "auto", ram, huge, statuses
                )
                self.assertEqual(baseline["hardware"], ["awk:ram", "awk:huge"])
                self.assertIn(expected, baseline["env"])

    def test_unknown_and_negative_hardware_facts_match(self):
        statuses = (
            ("config-env-memory:settings:1:0", 2),
            ("config-env-memory:limit:1:0", 1),
        )
        baseline, _ = self.assert_parity(
            "unknown-facts", self.base_config, "auto", "", "-1", statuses
        )
        self.assertEqual(baseline["hardware"], ["awk:ram", "awk:huge"])
        self.assertIn(b"TARI_MEM_LIMIT=12288m\n", baseline["env"])

    def test_off_and_remote_modes_skip_hardware(self):
        off = copy.deepcopy(self.base_config)
        off["tari"]["mode"] = "off"
        remote = copy.deepcopy(self.base_config)
        remote["tari"].update(
            mode="remote", remote={"host": "tari.example.com", "grpc_port": 18142}
        )
        for name, config in (("off", off), ("remote", remote)):
            with self.subTest(mode=name):
                baseline, entries = self.assert_parity(
                    name,
                    config,
                    "auto",
                    statuses=(("config-env-memory:settings:1:0", 2),),
                )
                self.assertEqual(baseline["hardware"], [])
                self.assertIn(b"TARI_MEM_LIMIT=0m\n", baseline["env"])
                self.assertFalse(any(":limit:" in entry for entry in entries))

    def test_explicit_limits_skip_hardware(self):
        config = copy.deepcopy(self.base_config)
        config["monero"]["mem_limit"] = "9g"
        baseline, entries = self.assert_parity(
            "explicit",
            config,
            "5g",
            statuses=(("config-env-memory:settings:1:0", 2),),
        )
        self.assertEqual(baseline["hardware"], [])
        self.assertIn(b"TARI_MEM_LIMIT=5g\n", baseline["env"])
        self.assertIn(b"MONERO_MEM_LIMIT=9g\n", baseline["env"])
        self.assertFalse(any(":limit:" in entry for entry in entries))

    def test_numeric_config_falls_back_to_bash(self):
        config = copy.deepcopy(self.base_config)
        config["tari"]["mem_limit"] = 8.0
        baseline, entries = self.assert_parity(
            "numeric", config, statuses=(("config-env-memory:settings:1:125", 1),)
        )
        self.assertIn(b"TARI_MEM_LIMIT=8.0\n", baseline["env"])
        self.assertEqual(entries, ["config-env-memory:settings:1:125"])

    def test_poisoned_settings_and_limit_plans_fall_back(self):
        poisoned = (
            '"$MEMORY_REAL_GO" "$@" | '
            "{ IFS= read -r -d '' discarded; printf 'poison\\0'; cat; }"
        )
        cases = {
            "settings": (None, poisoned + "; printf '0\\0trailing'"),
            "limit": ("auto", poisoned + "; printf '0\\0extra\\0'"),
        }
        for operation, (memory_limit, output) in cases.items():
            with self.subTest(operation=operation):
                log = self.directory / f"poison-{operation}.log"
                spy = self.make_spy(
                    f"poison-{operation}-spy",
                    'if [ "${PITHEAD_GO_HELPER:-}" = config-env-memory '
                    f'] && [ "${{1:-}}" = {operation} ]; then\n'
                    f'  printf "config-env-memory:{operation}:%s:poison\\n" "$#" '
                    '>>"$MEMORY_SPY_LOG"\n'
                    f"  {output}\n"
                    "  exit 0\n"
                    "fi\n"
                    'exec "$MEMORY_REAL_GO" "$@"\n',
                )
                baseline = self.invoke(
                    "bash", f"poison-{operation}", self.base_config, memory_limit
                )
                selected = self.invoke(
                    "go",
                    f"poison-{operation}",
                    self.base_config,
                    memory_limit,
                    binary=spy,
                    extra={"MEMORY_REAL_GO": str(GO_BINARY), "MEMORY_SPY_LOG": str(log)},
                )
                self.assertEqual(selected, baseline)
                self.assertEqual(
                    log.read_text().splitlines(),
                    [f"config-env-memory:{operation}:1:poison"],
                )


if __name__ == "__main__":
    unittest.main()
