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
ADAPTER = ROOT / "tests/go-parity/env_resources_reference.sh"
FIXTURES = ROOT / "tests/stack/fixtures/config-2.0.0"
GO_BINARY = ROOT / "go/bin/pithead"
CACHE = ROOT / ".go-cache/parity"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class EnvResourcesParityTests(unittest.TestCase):
    def setUp(self):
        CACHE.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=CACHE)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.base_config = json.loads((FIXTURES / "absent.json").read_text())

    def environment(self, implementation, binary=None, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(PITHEAD_IMPL=implementation, PITHEAD_GO_BINARY=str(binary or GO_BINARY))
        env.update(extra or {})
        return env

    def make_spy(self, name, resource_body=None):
        path = self.directory / name
        body = resource_body or (
            'if "$RESOURCES_REAL_GO" "$@" <"$payload"; then rc=0; else rc=$?; fi\n'
            '  rm -f "$payload"\n'
            "  trap - EXIT\n"
            '  exit "$rc"'
        )
        path.write_text(
            "#!/usr/bin/env bash\nset -Eeuo pipefail\n"
            'if [ "${PITHEAD_GO_HELPER:-}" = config-env-resources ]; then\n'
            '  payload="${RESOURCES_TRACE_LOG}.payload.$BASHPID"\n'
            "  trap 'rm -f \"$payload\"' EXIT\n"
            '  command cat >"$payload"\n'
            "  hex=$(command od -An -v -tx1 \"$payload\" | command tr -d ' \\n')\n"
            '  printf "resource:%s:%s:%s\\n" "${1:-}" "$#" "$hex" '
            '>>"$RESOURCES_TRACE_LOG"\n'
            f"  {body}\n"
            "fi\n"
            'exec "$RESOURCES_REAL_GO" "$@"\n'
        )
        path.chmod(0o755)
        return path

    def invoke(
        self,
        implementation,
        name,
        config,
        cores="8",
        binary=None,
        extra=None,
        sysctl_cores="",
    ):
        install = self.directory / f"{name}-{implementation}"
        install.mkdir()
        config_file = install / "fixture.json"
        if isinstance(config, str):
            config_file.write_text(config)
        else:
            config_file.write_text(json.dumps(config))
        trace = install / "trace.log"
        result = subprocess.run(  # noqa: S603
            [
                BASH,
                str(ADAPTER),
                str(ROOT),
                str(config_file),
                "0",
                cores,
                str(trace),
                sysctl_cores,
            ],
            cwd=install,
            env=self.environment(implementation, binary, extra),
            capture_output=True,
            check=False,
            timeout=30,
        )
        env_file = install / ".env"

        def normalize(data):
            return data.replace(str(install).encode(), b"@ROOT@")

        return {
            "process": (result.returncode, normalize(result.stdout), normalize(result.stderr)),
            "env": normalize(env_file.read_bytes()) if env_file.exists() else None,
            "mode": stat.S_IMODE(env_file.stat().st_mode) if env_file.exists() else None,
            "trace": trace.read_text().splitlines() if trace.exists() else [],
        }

    def assert_parity(self, name, config, cores="8", binary=None, extra=None, sysctl_cores=""):
        baseline = self.invoke("bash", name, config, cores, sysctl_cores=sysctl_cores)
        selected = self.invoke("go", name, config, cores, binary, extra, sysctl_cores=sysctl_cores)
        self.assertEqual(selected["process"], baseline["process"])
        self.assertEqual(selected["env"], baseline["env"])
        self.assertEqual(selected["mode"], baseline["mode"])
        if baseline["env"] is not None:
            self.assertEqual(baseline["mode"], 0o600)
        return baseline, selected

    def helper(self, operation, payload, args=()):
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY), operation, *args],
            env={**os.environ, "PITHEAD_GO_HELPER": "config-env-resources"},
            input=payload,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def auto_config(self):
        config = copy.deepcopy(self.base_config)
        config["monero"]["prep_blocks_threads"] = "auto"
        return config

    def test_private_protocol_values_and_strict_frames(self):
        good = {
            ("threads", b"2\0" + b"0\0"): b"4\0",
            ("threads", b"7\0" + b"0\0"): b"5\0",
            ("threads", b"10\0" + b"0\0"): b"8\0",
            ("peers", b"8\0" + b"0\0"): b"true\0",
            ("peers", b"0008\0" + b"0\0"): b"true\0",
            ("peers", b"7\0" + b"0\0"): b"false\0",
            ("peers", b"many\0" + b"0\0"): b"false\0",
        }
        for (operation, payload), expected in good.items():
            with self.subTest(operation=operation, payload=payload):
                result = self.helper(operation, payload)
                self.assertEqual(
                    (result.returncode, result.stdout, result.stderr), (0, expected, b"")
                )
        bad = (
            ("threads", b""),
            ("threads", b"7"),
            ("threads", b"7\0" + b"9\0"),
            ("threads", b"7\0" + b"0\0extra\0"),
            ("threads", b"07\0" + b"0\0"),
            ("threads", b"9223372036854775808\0" + b"0\0"),
            ("peers", b"8"),
            ("peers", b"8\0" + b"9\0"),
            ("peers", b"8\0" + b"0\0extra\0"),
            ("peers", b"9223372036854775808\0" + b"0\0"),
            ("other", b"8\0" + b"0\0"),
        )
        for operation, payload in bad:
            with self.subTest(operation=operation, payload=payload):
                result = self.helper(operation, payload)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))
        result = self.helper("threads", b"8\0" + b"0\0", ("extra",))
        self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))

    def test_canonical_core_clamps_and_native_selection(self):
        expected = {"2": "4", "6": "4", "7": "5", "9": "7", "10": "8", "64": "8"}
        for cores, threads in expected.items():
            with self.subTest(cores=cores):
                spy = self.make_spy(f"native-{cores}-spy")
                baseline, selected = self.assert_parity(
                    f"native-{cores}",
                    self.auto_config(),
                    cores,
                    spy,
                    {"RESOURCES_REAL_GO": str(GO_BINARY)},
                )
                self.assertIn(f"MONERO_PREP_THREADS={threads}\n".encode(), baseline["env"])
                trace = selected["trace"]
                threads_entry = f"resource:threads:1:{cores.encode().hex()}003000"
                peers_entry = "resource:peers:1:3438003000"
                self.assertLess(
                    trace.index("log:Rendering environment configuration (.env)..."),
                    trace.index(f"nproc:{cores}"),
                )
                self.assertLess(trace.index(f"nproc:{cores}"), trace.index(threads_entry))
                self.assertLess(trace.index(threads_entry), trace.index(peers_entry))
                self.assertLess(
                    trace.index(peers_entry),
                    trace.index(
                        f"log:Monero block-prep threads: {threads} | pool: mini | mode: local"
                    ),
                )

    def test_configured_threads_bypass_discovery_and_keep_bytes(self):
        for value in (6, "07"):
            with self.subTest(value=value):
                config = copy.deepcopy(self.base_config)
                config["monero"]["prep_blocks_threads"] = value
                spy = self.make_spy(f"configured-{value}-spy")
                baseline, selected = self.assert_parity(
                    f"configured-{value}",
                    config,
                    "poison",
                    spy,
                    {"RESOURCES_REAL_GO": str(GO_BINARY)},
                )
                self.assertIn(f"MONERO_PREP_THREADS={value}\n".encode(), baseline["env"])
                self.assertFalse(any(entry.startswith("nproc:") for entry in selected["trace"]))
                self.assertEqual(
                    [entry for entry in selected["trace"] if entry.startswith("resource:")],
                    ["resource:peers:1:3438003000"],
                )

    def test_sysctl_discovery_order_and_value_match(self):
        spy = self.make_spy("sysctl-spy")
        _, selected = self.assert_parity(
            "sysctl",
            self.auto_config(),
            "fail",
            spy,
            {"RESOURCES_REAL_GO": str(GO_BINARY)},
            "9",
        )
        trace = selected["trace"]
        threads = "resource:threads:1:39003000"
        self.assertLess(trace.index("nproc:fail"), trace.index("sysctl:9"))
        self.assertLess(trace.index("sysctl:9"), trace.index(threads))
        self.assertIn(b"MONERO_PREP_THREADS=7\n", selected["env"])

    def test_noncanonical_core_facts_fall_back_to_bash_arithmetic(self):
        cases = {
            "leading-zero": "010",
            "expression": "2+8",
            "overflow": "9223372036854775808",
            "minimum": "-9223372036854775808",
            "minimum-plus-one": "-9223372036854775807",
        }
        for name, cores in cases.items():
            with self.subTest(case=name):
                baseline, _ = self.assert_parity(name, self.auto_config(), cores)
                expected = (
                    b"MONERO_PREP_THREADS=6\n" if cores == "010" else b"MONERO_PREP_THREADS=8\n"
                )
                self.assertIn(expected, baseline["env"])

    def test_peer_bounds_strings_and_reference_errors_match(self):
        cases = (
            (8, True),
            (1024, True),
            ("0008", True),
            (7, False),
            (1025, False),
            ("many", False),
        )
        for value, valid in cases:
            with self.subTest(value=value):
                config = copy.deepcopy(self.base_config)
                config["monero"]["out_peers"] = value
                spy = self.make_spy(f"peers-{value}-spy")
                baseline, selected = self.assert_parity(
                    f"peers-{value}",
                    config,
                    binary=spy,
                    extra={"RESOURCES_REAL_GO": str(GO_BINARY)},
                )
                resource = f"resource:peers:1:{str(value).encode().hex()}003000"
                self.assertIn(resource, selected["trace"])
                if valid:
                    self.assertIn(f"MONERO_OUT_PEERS={value}\n".encode(), baseline["env"])
                else:
                    self.assertEqual(baseline["process"][0], 1)
                    message = (
                        f'monero.out_peers must be an integer between 8 and 1024 (got "{value}").'
                    )
                    self.assertIn(message.encode(), baseline["process"][2])
                    self.assertIn(f"error:{message}", selected["trace"])
                    self.assertLess(
                        selected["trace"].index(resource),
                        selected["trace"].index(f"error:{message}"),
                    )

    def test_peer_overflow_keeps_bash_numeric_diagnostic(self):
        config = copy.deepcopy(self.base_config)
        config["monero"]["out_peers"] = "9223372036854775808"
        spy = self.make_spy("peer-overflow-spy")
        baseline, selected = self.assert_parity(
            "peer-overflow",
            config,
            binary=spy,
            extra={"RESOURCES_REAL_GO": str(GO_BINARY)},
        )
        self.assertEqual(baseline["process"][0], 0)
        self.assertEqual(baseline["process"][2].count(b"integer expected"), 2)
        self.assertIn(b"MONERO_OUT_PEERS=9223372036854775808\n", baseline["env"])
        self.assertIn(
            "resource:peers:1:39323233333732303336383534373735383038003000",
            selected["trace"],
        )

    def test_missing_refused_and_malformed_helpers_fall_back(self):
        missing = self.directory / "missing-go"
        self.assert_parity("missing", self.auto_config(), "7", missing)
        cases = {
            "refused": "exit 125",
            "truncated": "printf '5'",
            "trailing": "printf '5\\0trailing'",
            "extra": "printf '5\\0extra\\0'",
            "poison": "printf 'poison\\0'",
        }
        for name, body in cases.items():
            with self.subTest(case=name):
                spy = self.make_spy(f"{name}-spy", body)
                _, selected = self.assert_parity(
                    name,
                    self.auto_config(),
                    "7",
                    spy,
                    {"RESOURCES_REAL_GO": str(GO_BINARY)},
                )
                self.assertEqual(
                    [entry for entry in selected["trace"] if entry.startswith("resource:")],
                    ["resource:threads:1:37003000", "resource:peers:1:3438003000"],
                )


if __name__ == "__main__":
    unittest.main()
