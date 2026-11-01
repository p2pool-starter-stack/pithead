import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_caddy as caddy  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/caddy_bind_reference.sh"


class CaddyBindParityTests(caddy.CaddyParityTests):
    def setUp(self):
        super().setUp()
        original_adapter = caddy.ADAPTER
        caddy.ADAPTER = ADAPTER
        self.addCleanup(setattr, caddy, "ADAPTER", original_adapter)

    def cases(self):
        appliance = {
            "CADDY_APPLIANCE": "true",
            "CADDY_SITE_HOSTS": "pithead.local",
            "DASHBOARD_SECURE": "true",
        }
        return {
            **super().cases(),
            "bind-bridges-duplicates": {
                **appliance,
                "CADDY_HOSTNAME_ADDRESSES": (
                    "10.0.0.2 172.28.0.1 172.28.0.10 10.0.0.2 198.51.100.8"
                ),
                "CADDY_BRIDGE_ADDRESSES": "172.28.0.1\n172.29.0.1",
                "CADDY_PUBLIC_ADDRESSES": "198.51.100.8",
            },
            "bind-empty": {
                **appliance,
                "CADDY_HOSTNAME_ADDRESSES": "",
            },
            "bind-private": {
                **appliance,
                "CADDY_HOSTNAME_ADDRESSES": "10.0.0.2 192.168.1.9",
            },
            "bind-public-only": {
                **appliance,
                "CADDY_HOSTNAME_ADDRESSES": "198.51.100.8 203.0.113.9",
                "CADDY_PUBLIC_ADDRESSES": "198.51.100.8 203.0.113.9",
            },
            "bind-lexical": {
                **appliance,
                "CADDY_HOSTNAME_ADDRESSES": (
                    "fd00::1 fe80::1%en0 host.name 12.3x ... 001.002.003.004"
                ),
            },
            "bind-prefix": {
                **appliance,
                "NETWORK_PREFIX": "172.28.0",
                "CADDY_HOSTNAME_ADDRESSES": "172.28.0.1 172.28.0.10",
            },
            "bind-empty-prefix": {
                **appliance,
                "NETWORK_PREFIX": "",
                "CADDY_HOSTNAME_ADDRESSES": ".1 10.0.0.1",
            },
            "bind-prefix-suffix": {
                **appliance,
                "NETWORK_PREFIX": "172.28.0.",
                "CADDY_HOSTNAME_ADDRESSES": "172.28.0.1 172.28.0..1",
            },
            "bind-diy-bypass": {
                "CADDY_APPLIANCE": "false",
                "CADDY_HOSTNAME_ADDRESSES": "10.0.0.2",
            },
            "bind-public-exposure-bypass": {
                **appliance,
                "DASHBOARD_EXPOSE_PUBLIC_IP": "true",
                "CADDY_HOSTNAME_ADDRESSES": "10.0.0.2",
            },
        }

    def test_native_bind_cases_match_complete_file(self):
        expected = {
            "bridges": "10.0.0.2 172.28.0.10 10.0.0.2 127.0.0.1 ::1",
            "empty": "127.0.0.1 ::1",
            "private": "10.0.0.2 192.168.1.9 127.0.0.1 ::1",
            "public": "127.0.0.1 ::1",
            "lexical": ("fd00::1 fe80::1%en0 ... 001.002.003.004 127.0.0.1 ::1"),
            "prefix": "172.28.0.10 127.0.0.1 ::1",
            "empty-prefix": ".1 10.0.0.1 127.0.0.1 ::1",
            "prefix-suffix": "172.28.0.1 127.0.0.1 ::1",
        }
        cases = self.cases()
        mapping = {
            "bridges": "bind-bridges-duplicates",
            "empty": "bind-empty",
            "private": "bind-private",
            "public": "bind-public-only",
            "lexical": "bind-lexical",
            "prefix": "bind-prefix",
            "empty-prefix": "bind-empty-prefix",
            "prefix-suffix": "bind-prefix-suffix",
        }
        for label, name in mapping.items():
            with self.subTest(case=label):
                baseline = self.invoke("bash", f"native-{label}", cases[name])
                selected = self.invoke("go", f"native-{label}", cases[name])
                self.assertEqual(selected, baseline)
                self.assertEqual(baseline[0], 0)
                self.assertIn(f"    bind {expected[label]}\n".encode(), baseline[4])

    def test_empty_candidates_with_system_bash(self):
        original_bash = caddy.BASH
        caddy.BASH = "/bin/bash"
        self.addCleanup(setattr, caddy, "BASH", original_bash)
        for name in ("bind-empty", "bind-public-only"):
            with self.subTest(case=name):
                case = self.cases()[name]
                baseline = self.invoke("bash", f"system-{name}", case)
                selected = self.invoke("go", f"system-{name}", case)
                self.assertEqual(selected, baseline)
                self.assertEqual(baseline[0], 0)
                self.assertIn(b"    bind 127.0.0.1 ::1\n", baseline[4])

    def test_helper_runs_only_for_private_appliance_bind(self):
        spy_log = self.directory / "bind-spy.log"
        spy = self.make_spy(
            "bind-spy",
            'if "$CADDY_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "${1:-}" "$rc" '
            '>>"$CADDY_BIND_SPY_LOG"\n'
            'exit "$rc"\n',
        )
        cases = self.cases()
        for name in (
            "bind-private",
            "bind-diy-bypass",
            "bind-public-exposure-bypass",
        ):
            self.invoke(
                "go",
                f"gate-{name}",
                cases[name],
                spy,
                extra_env={
                    "CADDY_BIND_SPY_LOG": str(spy_log),
                    "CADDY_REAL_GO": str(caddy.GO_BINARY),
                },
            )
        invocations = spy_log.read_text().splitlines()
        self.assertEqual(invocations.count("config-caddy-bind::0"), 1)
        self.assertEqual(invocations.count("config-caddy:prefix:0"), 3)
        self.assertEqual(invocations.count("config-caddy:main:0"), 3)

    def test_bind_fallback_preserves_callbacks_and_bytes(self):
        case = self.cases()["bind-bridges-duplicates"]
        baseline = self.invoke("bash", "fallback-baseline", case)
        scripts = {
            "refused": 'case "${PITHEAD_GO_HELPER:-}" in\n'
            'config-caddy-bind) printf called >>"$BIND_LOG"; exit 125 ;;\n'
            'esac\nexec "$CADDY_REAL_GO" "$@"\n',
            "malformed": 'case "${PITHEAD_GO_HELPER:-}" in\n'
            'config-caddy-bind) printf "poison"; exit 0 ;;\n'
            'esac\nexec "$CADDY_REAL_GO" "$@"\n',
            "empty-field": 'case "${PITHEAD_GO_HELPER:-}" in\n'
            'config-caddy-bind) printf "\\0"; exit 0 ;;\n'
            'esac\nexec "$CADDY_REAL_GO" "$@"\n',
            "trailing": 'case "${PITHEAD_GO_HELPER:-}" in\n'
            'config-caddy-bind) printf "poison\\0garbage\\0"; exit 0 ;;\n'
            'esac\nexec "$CADDY_REAL_GO" "$@"\n',
            "nonzero": 'case "${PITHEAD_GO_HELPER:-}" in\n'
            'config-caddy-bind) printf "poison\\0"; exit 17 ;;\n'
            'esac\nexec "$CADDY_REAL_GO" "$@"\n',
        }
        for label, body in scripts.items():
            with self.subTest(case=label):
                bind_log = self.directory / f"{label}.log"
                spy = self.make_spy(label, body)
                selected = self.invoke(
                    "go",
                    f"fallback-{label}",
                    case,
                    spy,
                    extra_env={
                        "BIND_LOG": str(bind_log),
                        "CADDY_REAL_GO": str(caddy.GO_BINARY),
                    },
                )
                self.assertEqual(selected, baseline)
                self.assertEqual(selected[5].count(b"hostname\n"), 1)
                self.assertEqual(selected[5].count(b"bridges\n"), 1)
                self.assertEqual(selected[5].count(b"public:"), 5)
                if label == "refused":
                    self.assertEqual(bind_log.read_bytes(), b"called")

    def test_nonpublic_classifier_status_does_not_fire_err_trap(self):
        case = {
            **self.cases()["bind-private"],
            "CADDY_HOSTNAME_ADDRESSES": "10.0.0.2 10.0.0.3",
        }
        results = []
        for implementation in ("bash", "go"):
            trap_log = self.directory / f"{implementation}-err.log"
            results.append(
                self.invoke(
                    implementation,
                    "classifier-status",
                    case,
                    extra_env={"CADDY_ERR_LOG": str(trap_log)},
                )
            )
            self.assertFalse(trap_log.exists())
        self.assertEqual(results[1], results[0])
        self.assertIn(b"public:10.0.0.2\npublic:10.0.0.3\n", results[0][5])

    def test_missing_binary_and_internal_marker_selection(self):
        case = self.cases()["bind-private"]
        baseline = self.invoke("bash", "marker-baseline", case)
        absent = self.directory / "absent-go"
        selected = self.invoke("go", "missing", case, absent)
        self.assertEqual(selected, baseline)

        spy_log = self.directory / "marker.log"
        spy = self.make_spy(
            "marker-spy",
            'if "$CADDY_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'printf "%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "$rc" >>"$MARKER_LOG"\n'
            'exit "$rc"\n',
        )
        selected = self.invoke(
            "bash",
            "marker",
            case,
            marker=spy,
            extra_env={
                "MARKER_LOG": str(spy_log),
                "CADDY_REAL_GO": str(caddy.GO_BINARY),
            },
        )
        self.assertEqual(selected, baseline)
        self.assertIn("config-caddy-bind:0", spy_log.read_text().splitlines())

    def test_helper_protocol_refuses_invalid_frames(self):
        valid = b" bridges \x00172.28.0\x001\x0010.0.0.2\x000\x00"
        frames = (
            (b"arg", valid),
            (b"", b""),
            (b"", valid[:-1]),
            (b"", valid.replace(b"\x001\x00", b"\x00one\x00", 1)),
            (b"", valid.replace(b"\x001\x00", b"\x002\x00", 1)),
            (b"", valid[:-2] + b"9\x00"),
            (b"", valid + b"extra\x00"),
        )
        for argument, frame in frames:
            with self.subTest(argument=argument, frame=frame):
                command = [str(caddy.GO_BINARY)]
                if argument:
                    command.append(argument.decode())
                result = subprocess.run(  # noqa: S603
                    command,
                    env={**os.environ, "PITHEAD_GO_HELPER": "config-caddy-bind"},
                    input=frame,
                    capture_output=True,
                    check=False,
                    timeout=15,
                )
                self.assertEqual(
                    (result.returncode, result.stdout, result.stderr),
                    (125, b"", b""),
                )


if __name__ == "__main__":
    caddy.unittest.main()
