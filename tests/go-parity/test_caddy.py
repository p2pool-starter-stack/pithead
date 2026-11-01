import base64
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/caddy_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

HASH = "$2y$14$PARITYbcrypthashvalue000000000000000000000000000000"
HASH_B64 = base64.b64encode(HASH.encode()).decode()


class CaddyParityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)

    def environment(self, implementation, case, binary=None, extra_env=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            CADDY_PARITY_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            DASHBOARD_SECURE="false",
            HOST_PORT="",
            HOST_IP="box.lan",
            DASHBOARD_AUTH_USER="operator",
            DASHBOARD_AUTH_HASH_B64="",
            DASHBOARD_EXPOSE_PUBLIC_IP="false",
            DASHBOARD_ONION_ENABLED="false",
            DASHBOARD_ONION="",
            NETWORK_PREFIX="172.28.0",
            CADDY_APPLIANCE="false",
            CADDY_SITE_HOSTS="box.lan",
            CADDY_HOSTNAME_ADDRESSES="",
            CADDY_BRIDGE_ADDRESSES="",
            CADDY_PUBLIC_ADDRESSES="",
            CADDY_MINT_CERT="true",
            CADDY_MINT_RC="0",
            CADDY_CAT_RC="0",
        )
        env.update(case)
        env.update(extra_env or {})
        return env

    def invoke(self, implementation, name, case, binary=None, marker=None, extra_env=None):
        work = self.directory / f"{name}-{implementation}-{len(list(self.directory.iterdir()))}"
        work.mkdir()
        target = work / "Caddyfile"
        calls = work / "calls"
        tls = work / "tls"
        tls.mkdir()
        if case.get("CADDY_CERT") == "present":
            (tls / "wizard.crt").write_text("certificate\n")
            (tls / "wizard.key").write_text("key\n")
        env = self.environment(implementation, case, binary, extra_env)
        env.update(CADDY_CALL_LOG=str(calls), CADDY_TLS_DIR=str(tls))
        if marker is not None:
            env["PITHEAD_GO_CONFIG_DOCUMENT_BINARY"] = str(marker)
        result = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(target)],
            env=env,
            capture_output=True,
            check=False,
            timeout=15,
        )
        return (
            result.returncode,
            result.stdout,
            result.stderr,
            target.exists(),
            target.read_bytes() if target.exists() else b"",
            calls.read_bytes() if calls.exists() else b"",
        )

    def make_spy(self, name, body):
        path = self.directory / name
        path.write_text("#!/usr/bin/env bash\nset -Eeuo pipefail\n" + body)
        path.chmod(0o755)
        return path

    def invoke_path_error(self, implementation, target, calls):
        env = self.environment(implementation, {})
        env.update(CADDY_CALL_LOG=str(calls), CADDY_TLS_DIR=str(self.directory / "tls"))
        return subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(target)],
            env=env,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def cases(self):
        appliance = {
            "CADDY_APPLIANCE": "true",
            "CADDY_SITE_HOSTS": "pithead.local 192.168.2.50 [fd00::50]",
            "CADDY_HOSTNAME_ADDRESSES": (
                "192.168.2.50 172.28.0.1 198.51.100.8 fd00::50 bridge-name"
            ),
            "CADDY_BRIDGE_ADDRESSES": "172.28.0.1",
            "CADDY_PUBLIC_ADDRESSES": "198.51.100.8",
        }
        matrix = {
            f"matrix-{secure}-{port or 'empty'}-{'auth' if auth else 'open'}": {
                "DASHBOARD_SECURE": secure,
                "HOST_PORT": port,
                **({"DASHBOARD_AUTH_HASH_B64": HASH_B64} if auth else {}),
            }
            for secure in ("false", "true")
            for port in ("", "80", "443", "8443")
            for auth in (False, True)
        }
        return {
            **matrix,
            "http-default": {},
            "http-standard-port": {"HOST_PORT": "80"},
            "http-custom-auth": {
                "HOST_PORT": "8080",
                "DASHBOARD_AUTH_HASH_B64": HASH_B64,
            },
            "https-default": {"DASHBOARD_SECURE": "true"},
            "https-standard-port": {"DASHBOARD_SECURE": "true", "HOST_PORT": "443"},
            "https-custom": {"DASHBOARD_SECURE": "true", "HOST_PORT": "8443"},
            "ipv6-pinned": {
                "DASHBOARD_SECURE": "true",
                "HOST_IP": "[fd00::50]",
                "CADDY_SITE_HOSTS": "[fd00::50]",
            },
            "appliance-no-cert": {**appliance, "DASHBOARD_SECURE": "true"},
            "appliance-cert-no-mint": {
                **appliance,
                "DASHBOARD_SECURE": "true",
                "CADDY_CERT": "present",
                "CADDY_MINT_CERT": "false",
            },
            "appliance-mint-failure": {
                **appliance,
                "DASHBOARD_SECURE": "true",
                "CADDY_CERT": "present",
                "CADDY_MINT_RC": "17",
            },
            "appliance-public-exposure": {
                **appliance,
                "DASHBOARD_SECURE": "true",
                "DASHBOARD_EXPOSE_PUBLIC_IP": "true",
                "CADDY_CERT": "present",
            },
            "onion-placeholder": {
                **appliance,
                "DASHBOARD_SECURE": "true",
                "DASHBOARD_AUTH_HASH_B64": HASH_B64,
                "DASHBOARD_ONION_ENABLED": "true",
                "DASHBOARD_ONION": "placeholder",
            },
            "onion-real": {
                **appliance,
                "DASHBOARD_SECURE": "true",
                "DASHBOARD_AUTH_HASH_B64": HASH_B64,
                "DASHBOARD_ONION_ENABLED": "true",
                "DASHBOARD_ONION": "parityexample234567890123456789012345678901234567890123.onion",
                "CADDY_CERT": "present",
            },
            "onion-without-auth": {
                "DASHBOARD_SECURE": "true",
                "DASHBOARD_ONION_ENABLED": "true",
            },
            "malformed-auth": {"DASHBOARD_AUTH_HASH_B64": "%%%not-base64%%%"},
            "cat-write-failure": {
                "DASHBOARD_SECURE": "true",
                "HOST_PORT": "8443",
                "CADDY_CAT_RC": "23",
            },
        }

    def test_whole_render_matches_reference(self):
        spy_log = self.directory / "spy.log"
        spy = self.make_spy(
            "go-spy",
            'if "$CADDY_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "${1:-}" "$rc" '
            '>>"$CADDY_SPY_LOG"\n'
            'exit "$rc"\n',
        )
        for name, case in self.cases().items():
            with self.subTest(case=name):
                baseline = self.invoke("bash", name, case)
                selected = self.invoke(
                    "go",
                    name,
                    case,
                    spy,
                    extra_env={
                        "CADDY_SPY_LOG": str(spy_log),
                        "CADDY_REAL_GO": str(GO_BINARY),
                    },
                )
                self.assertEqual(selected, baseline)
                if name == "onion-without-auth":
                    self.assertEqual(baseline[0], 1)
                    self.assertIn(b"reverse_proxy 127.0.0.1:8000", baseline[4])
                    self.assertNotIn(b"http://172.28.0.1", baseline[4])
                elif name == "appliance-cert-no-mint":
                    self.assertNotIn(b"mint\n", baseline[5])
                elif name in {"appliance-no-cert", "appliance-mint-failure"}:
                    self.assertIn(b"mint\n", baseline[5])
                elif name == "cat-write-failure":
                    self.assertEqual(baseline[0], 23)
                    self.assertEqual(baseline[4], b"{\n    auto_https disable_redirects\n}\n\n")
        invocations = spy_log.read_text().splitlines()
        self.assertIn("config-caddy:prefix:0", invocations)
        self.assertIn("config-caddy:main:0", invocations)
        self.assertIn("config-caddy:onion-http:0", invocations)
        self.assertIn("config-caddy:onion-https:0", invocations)
        self.assertNotIn(HASH_B64, spy_log.read_text())

    def test_helper_refusal_and_missing_binary_fall_back(self):
        case = {
            "DASHBOARD_SECURE": "true",
            "DASHBOARD_AUTH_HASH_B64": HASH_B64,
            "DASHBOARD_ONION_ENABLED": "true",
            "DASHBOARD_ONION": "placeholder",
        }
        baseline = self.invoke("bash", "fallback", case)
        refused_log = self.directory / "refused.log"
        refused = self.make_spy(
            "refused",
            'printf "%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "${1:-}" >>"$REFUSED_LOG"\nexit 125\n',
        )
        self.assertEqual(
            self.invoke(
                "go", "refused", case, refused, extra_env={"REFUSED_LOG": str(refused_log)}
            ),
            baseline,
        )
        self.assertIn("config-caddy:main", refused_log.read_text().splitlines())
        missing = self.directory / "absent-go"
        poison_log = self.directory / "missing-poison.log"
        poison = self.make_spy(
            "missing-poison",
            'printf called >"$POISON_LOG"\nexec "$CADDY_REAL_GO" "$@"\n',
        )
        self.assertEqual(
            self.invoke(
                "go",
                "missing",
                case,
                missing,
                marker=poison,
                extra_env={
                    "POISON_LOG": str(poison_log),
                    "CADDY_REAL_GO": str(GO_BINARY),
                },
            ),
            baseline,
        )
        self.assertFalse(poison_log.exists())

    def test_marker_enables_native_helper(self):
        spy_log = self.directory / "marker.log"
        spy = self.make_spy(
            "marker-spy",
            'if "$CADDY_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "${1:-}" "$rc" '
            '>>"$CADDY_SPY_LOG"\n'
            'exit "$rc"\n',
        )
        baseline = self.invoke("bash", "marker-baseline", {})
        selected = self.invoke(
            "bash",
            "marker",
            {},
            marker=spy,
            extra_env={
                "CADDY_SPY_LOG": str(spy_log),
                "CADDY_REAL_GO": str(GO_BINARY),
            },
        )
        self.assertEqual(selected, baseline)
        self.assertIn("config-caddy:main:0", spy_log.read_text().splitlines())

    def test_unknown_helper_section_is_silent_refusal(self):
        result = subprocess.run(  # noqa: S603
            [str(GO_BINARY), "unknown"],
            env={**os.environ, "PITHEAD_GO_HELPER": "config-caddy"},
            input=b"\0" * 11,
            capture_output=True,
            check=False,
            timeout=15,
        )
        self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))

    def test_unwritable_target_error_matches_reference(self):
        target = self.directory / "target-is-directory"
        target.mkdir()
        (self.directory / "tls").mkdir()
        baseline = self.invoke_path_error("bash", target, self.directory / "bash-calls")
        selected = self.invoke_path_error("go", target, self.directory / "go-calls")
        self.assertEqual(
            (selected.returncode, selected.stdout, selected.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        self.assertNotEqual(baseline.returncode, 0)


if __name__ == "__main__":
    unittest.main()
