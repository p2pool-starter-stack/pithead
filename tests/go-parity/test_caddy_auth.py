import base64
import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/caddy_auth_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

HASH = b"$2y$14$PARITYbcrypthashvalue000000000000000000000000000000"
HASH_B64 = base64.b64encode(HASH).decode()


class CaddyAuthParityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)

    def environment(self, implementation, case, binary=None, extra=None):
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
        env.update(extra or {})
        if env.pop("CADDY_AUTH_UNSET_USER", "0") == "1":
            env.pop("DASHBOARD_AUTH_USER", None)
        return env

    def invoke(self, implementation, name, case, binary=None, extra=None):
        work = self.directory / f"{name}-{implementation}"
        work.mkdir()
        target = work / "Caddyfile"
        calls = work / "calls"
        helper_calls = work / "helper-calls"
        tls = work / "tls"
        tls.mkdir()
        env = self.environment(implementation, case, binary, extra)
        env.update(
            CADDY_CALL_LOG=str(calls),
            CADDY_AUTH_HELPER_LOG=str(helper_calls),
            CADDY_TLS_DIR=str(tls),
        )
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
            helper_calls.read_bytes() if helper_calls.exists() else b"",
        )

    def make_helper(self, name, body):
        path = self.directory / name
        path.write_text("#!/usr/bin/env bash\nset -Eeuo pipefail\n" + body)
        path.chmod(0o755)
        return path

    def spy(self):
        return self.make_helper(
            "go-spy",
            'if "$CADDY_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "${1:-}" "$rc" '
            '>>"$CADDY_AUTH_HELPER_LOG"\n'
            'exit "$rc"\n',
        )

    def payload(self, fields):
        return b"\0".join(fields) + b"\0"

    def helper(self, operation, fields, binary=GO_BINARY):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env["PITHEAD_GO_HELPER"] = "config-caddy-auth"
        result = subprocess.run(  # noqa: S603
            [str(binary), operation],
            env=env,
            input=self.payload(fields),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return result.returncode, result.stdout, result.stderr

    def auth_cases(self):
        values = {
            "empty": b"",
            "bcrypt": HASH,
            "binary": b"\xff\xfeBIN",
            "unicode": "päss-東京".encode(),
            "controls": b"line\x01tab\tend",
            "trailing-newlines": b"hash\n\n",
        }
        return {
            name: {
                "DASHBOARD_AUTH_USER": "operator name\tvalue",
                "DASHBOARD_AUTH_HASH_B64": base64.b64encode(value).decode(),
            }
            for name, value in values.items()
        }

    def test_complete_render_matches_reference_with_native_auth(self):
        spy = self.spy()
        for name, case in self.auth_cases().items():
            with self.subTest(case=name):
                baseline = self.invoke("bash", name, case)
                selected = self.invoke(
                    "go",
                    name,
                    case,
                    spy,
                    {
                        "CADDY_REAL_GO": str(GO_BINARY),
                    },
                )
                self.assertEqual(selected[:6], baseline[:6])
                calls = selected[6].decode().splitlines()
                self.assertEqual(
                    calls,
                    [
                        "config-caddy-auth:auth:0",
                        "config-caddy:prefix:0",
                        "config-caddy-auth:boot:0",
                        "config-caddy:main:0",
                    ],
                )
                if case["DASHBOARD_AUTH_HASH_B64"]:
                    self.assertNotIn(case["DASHBOARD_AUTH_HASH_B64"], selected[6].decode())

    def test_native_auth_avoids_openssl_and_sha_commands(self):
        fake_bin = self.directory / "fake-bin"
        fake_bin.mkdir()
        for command, status in (("openssl", 93), ("sha256sum", 94), ("shasum", 95)):
            fake = fake_bin / command
            fake.write_text(f"#!/usr/bin/env bash\nexit {status}\n")
            fake.chmod(0o755)
        spy = self.spy()
        case = {"DASHBOARD_AUTH_HASH_B64": HASH_B64}
        baseline = self.invoke("bash", "tools-baseline", case)
        selected = self.invoke(
            "go",
            "tools-native",
            case,
            spy,
            {
                "CADDY_REAL_GO": str(GO_BINARY),
                "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
            },
        )
        self.assertEqual(selected[:6], baseline[:6])
        calls = selected[6].decode().splitlines()
        self.assertEqual(
            calls,
            [
                "config-caddy-auth:auth:0",
                "config-caddy:prefix:0",
                "config-caddy-auth:boot:0",
                "config-caddy:main:0",
            ],
        )

    def test_direct_helper_contract(self):
        for name, raw in (
            ("empty", b""),
            ("bcrypt", HASH),
            ("binary", b"\xff\xfeBIN"),
            ("unicode", "päss-東京".encode()),
            ("controls", b"line\x01tab\tend"),
            ("trailing-newlines", b"hash\n\n"),
        ):
            with self.subTest(operation="auth", case=name):
                encoded = base64.b64encode(raw)
                result = self.helper("auth", [b"operator", encoded, b"0"])
                trimmed = raw.rstrip(b"\n")
                expected = (
                    b""
                    if encoded == b""
                    else b"    basic_auth {\n        operator " + trimmed + b"\n    }"
                )
                self.assertEqual(result, (0, expected + b"\0", b""))
        for encoded in (b"", HASH_B64.encode(), b"YWJjZA=="):
            with self.subTest(operation="boot", value=encoded):
                result = self.helper("boot", [encoded, b"0"])
                expected = hashlib.sha256(b"pithead-boot-health-v1:" + encoded).hexdigest().encode()
                self.assertEqual(result, (0, expected + b"\0", b""))

    def test_invalid_frames_are_silent_refusals(self):
        invalid = (
            ("auth", [b"operator", b"%%%", b"0"]),
            ("auth", [b"operator", b"YQ", b"0"]),
            ("auth", [b"operator", base64.b64encode(b"a\0b"), b"0"]),
            ("auth", [b"operator", HASH_B64.encode()]),
            ("auth", [b"operator", HASH_B64.encode(), b"1"]),
            ("auth", [b"operator", HASH_B64.encode(), b"0", b"extra"]),
            ("boot", [HASH_B64.encode()]),
            ("boot", [HASH_B64.encode(), b"1"]),
            ("boot", [HASH_B64.encode(), b"0", b"extra"]),
            ("unknown", [b"0"]),
        )
        for operation, fields in invalid:
            with self.subTest(operation=operation, fields=fields):
                self.assertEqual(self.helper(operation, fields), (125, b"", b""))

    def test_refused_malformed_and_missing_hook_fall_back(self):
        case = {"DASHBOARD_AUTH_HASH_B64": HASH_B64}
        baseline = self.invoke("bash", "fallback-baseline", case)
        delegate = (
            '[ "${PITHEAD_GO_HELPER:-}" = config-caddy-auth ] || exec "$CADDY_REAL_GO" "$@"\n'
        )
        helpers = {
            "refused": self.make_helper("refused", delegate + "exit 125\n"),
            "extra": self.make_helper("extra", delegate + "printf 'poison\\0extra\\0'\n"),
        }
        for name, helper in helpers.items():
            with self.subTest(case=name):
                selected = self.invoke("go", name, case, helper, {"CADDY_REAL_GO": str(GO_BINARY)})
                self.assertEqual(selected[:6], baseline[:6])
        malformed = {"DASHBOARD_AUTH_HASH_B64": "%%%not-base64%%%"}
        self.assertEqual(
            self.invoke("go", "malformed", malformed)[:6],
            self.invoke("bash", "malformed-baseline", malformed)[:6],
        )
        whitespace = {"DASHBOARD_AUTH_HASH_B64": "aGFz\naA=="}
        whitespace_spy = self.spy()
        whitespace_selected = self.invoke(
            "go",
            "whitespace",
            whitespace,
            whitespace_spy,
            {"CADDY_REAL_GO": str(GO_BINARY)},
        )
        self.assertEqual(
            whitespace_selected[:6],
            self.invoke("bash", "whitespace-baseline", whitespace)[:6],
        )
        self.assertIn("config-caddy-auth:auth:125", whitespace_selected[6].decode().splitlines())
        unset_user = {
            "DASHBOARD_AUTH_HASH_B64": HASH_B64,
            "CADDY_AUTH_UNSET_USER": "1",
        }
        self.assertEqual(
            self.invoke("go", "unset-user", unset_user)[:6],
            self.invoke("bash", "unset-user-baseline", unset_user)[:6],
        )
        missing = self.invoke(
            "go",
            "missing-hook",
            case,
            extra={"CADDY_AUTH_WITHOUT_GO_HOOK": "1"},
        )
        self.assertEqual(missing[:6], baseline[:6])

    def test_closed_output_fails_silently(self):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env["PITHEAD_GO_HELPER"] = "config-caddy-auth"
        process = subprocess.Popen(  # noqa: S603
            [str(GO_BINARY), "auth"],
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if process.stdin is None or process.stdout is None or process.stderr is None:
            self.fail("missing helper pipe")
        process.stdout.close()
        process.stdin.write(self.payload([b"operator", HASH_B64.encode(), b"0"]))
        process.stdin.close()
        returncode = process.wait(timeout=15)
        stderr = process.stderr.read()
        process.stderr.close()
        self.assertNotEqual(returncode, 0)
        self.assertEqual(stderr, b"")


if __name__ == "__main__":
    unittest.main()
