import base64
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/caddy_sites_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

HASH = "$2y$14$PARITYbcrypthashvalue000000000000000000000000000000"
HASH_B64 = base64.b64encode(HASH.encode()).decode()
ONION = "parityexample234567890123456789012345678901234567890123.onion"


class CaddySiteParityTests(unittest.TestCase):
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

    def make_spy(self):
        path = self.directory / "go-spy"
        path.write_text(
            "#!/usr/bin/env bash\n"
            "set -Eeuo pipefail\n"
            'if "$CADDY_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'printf "%s:%s:%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" '
            '"${1:-}" "${2:-legacy}" "$#" "$rc" >>"$CADDY_SPY_LOG"\n'
            'exit "$rc"\n'
        )
        path.chmod(0o755)
        return path

    def invoke(self, implementation, name, case, binary=None, files=(), extra_env=None):
        work = self.directory / f"{name}-{implementation}"
        work.mkdir()
        for filename in files:
            (work / filename).write_text(filename)
        target = work / "Caddyfile"
        calls = work / "calls"
        spy_log = work / "spy.log"
        tls = work / "tls"
        tls.mkdir()
        env = self.environment(implementation, case, binary, extra_env)
        env.update(
            CADDY_CALL_LOG=str(calls),
            CADDY_TLS_DIR=str(tls),
            CADDY_SPY_LOG=str(spy_log),
            CADDY_REAL_GO=str(GO_BINARY),
        )
        result = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(target)],
            cwd=work,
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
            spy_log.read_bytes() if spy_log.exists() else b"",
        )

    def render_cases(self):
        return {
            "duplicates-custom-port": (
                {
                    "DASHBOARD_SECURE": "true",
                    "HOST_PORT": "8443",
                    "CADDY_SITE_HOSTS": "one.local one.local [fd00::1]",
                },
                (),
                b"https://one.local:8443, https://one.local:8443, https://[fd00::1]:8443 {",
            ),
            "empty": ({"CADDY_SITE_HOSTS": ""}, (), b" {\n"),
            "port-trailing-newlines": (
                {"HOST_PORT": "8080\n\n", "CADDY_SITE_HOSTS": "one.local"},
                (),
                b"http://one.local:8080 {",
            ),
            "ascii-whitespace": (
                {"CADDY_SITE_HOSTS": "one.local\t two.local\nthree.local"},
                (),
                b"http://one.local, http://two.local, http://three.local {",
            ),
            "unicode": (
                {"CADDY_SITE_HOSTS": "café.local 東京.local"},
                (),
                "http://café.local, http://東京.local {".encode(),
            ),
            "glob": (
                {"CADDY_SITE_HOSTS": "*.site"},
                ("beta.site", "alpha.site"),
                b"http://alpha.site, http://beta.site {",
            ),
            "colon-ifs": (
                {
                    "CADDY_SITE_HOSTS": "one.local:two.local",
                    "CADDY_TEST_IFS_MODE": "colon",
                },
                (),
                b"http://one.local, http://two.local {",
            ),
            "empty-ifs": (
                {
                    "CADDY_SITE_HOSTS": "one.local two.local",
                    "CADDY_TEST_IFS_MODE": "empty",
                },
                (),
                b"http://one.local two.local {",
            ),
            "all-sections": (
                {
                    "DASHBOARD_SECURE": "true",
                    "HOST_PORT": "443",
                    "CADDY_SITE_HOSTS": "pithead.local [fd00::50]",
                    "DASHBOARD_AUTH_HASH_B64": HASH_B64,
                    "DASHBOARD_ONION_ENABLED": "true",
                    "DASHBOARD_ONION": ONION,
                },
                (),
                b"https://pithead.local, https://[fd00::50] {",
            ),
        }

    def test_complete_render_matches_reference_with_native_site_frames(self):
        spy = self.make_spy()
        sections = set()
        for name, (case, files, expected) in self.render_cases().items():
            with self.subTest(case=name):
                baseline = self.invoke("bash", name, case, files=files)
                selected = self.invoke("go", name, case, spy, files)
                self.assertEqual(selected[:6], baseline[:6])
                self.assertEqual(baseline[0], 0)
                self.assertIn(expected, baseline[4])
                invocations = selected[6].decode().splitlines()
                self.assertTrue(invocations)
                for invocation in invocations:
                    helper, section, version, count, status = invocation.split(":")
                    self.assertEqual(
                        (helper, version, count, status), ("config-caddy", "sites-v1", "2", "0")
                    )
                    sections.add(section)
        self.assertEqual(sections, {"prefix", "main", "onion-http", "onion-https"})

    def helper(self, args, payload):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env["PITHEAD_GO_HELPER"] = "config-caddy"
        result = subprocess.run(  # noqa: S603
            [str(GO_BINARY), *args],
            env=env,
            input=payload,
            capture_output=True,
            check=False,
            timeout=15,
        )
        return result.returncode, result.stdout, result.stderr

    def payload(self, fields):
        return b"\0".join(value.encode() for value in fields) + b"\0"

    def legacy_fields(self, secure, port, hosts):
        suffix = "" if port in ({"true": "443", "false": "80"}[secure], "") else f":{port}"
        http = ", ".join(f"http://{host}{suffix}" for host in hosts).rstrip("\n")
        https = ", ".join(f"https://{host}{suffix}" for host in hosts).rstrip("\n")
        return [
            secure,
            port,
            "box.lan",
            http,
            https,
            "127.0.0.1 ::1",
            "    basic_auth {}",
            "    tls internal",
            "capability",
            "172.28.0",
            ONION,
        ]

    def tagged_fields(self, secure, port, hosts, status="0"):
        return [
            secure,
            port,
            "box.lan",
            str(len(hosts)),
            *hosts,
            "127.0.0.1 ::1",
            "    basic_auth {}",
            "    tls internal",
            "capability",
            "172.28.0",
            ONION,
            status,
        ]

    def test_tagged_contract_matches_legacy_contract(self):
        for secure, port, hosts in (
            ("false", "", ["one.local", "[fd00::1]"]),
            ("false", "80", ["one.local"]),
            ("false", "8080", ["one.local"]),
            ("true", "443", ["café.local", "東京.local"]),
            ("true", "8443", ["one.local", "one.local"]),
            ("true", "8443\n\n", ["one.local", "one.local"]),
        ):
            for section in ("prefix", "main", "onion-http", "onion-https"):
                with self.subTest(secure=secure, port=port, hosts=hosts, section=section):
                    legacy = self.helper(
                        [section], self.payload(self.legacy_fields(secure, port, hosts))
                    )
                    tagged = self.helper(
                        [section, "sites-v1"], self.payload(self.tagged_fields(secure, port, hosts))
                    )
                    self.assertEqual(tagged, legacy)
                    self.assertEqual(tagged[0], 0)
                    self.assertTrue(tagged[1].endswith(b"."))

    def test_malformed_tagged_frames_are_silent_refusals(self):
        fields = self.tagged_fields("true", "443", ["one.local", "two.local"])
        payload = self.payload(fields)
        malformed = {
            "empty": b"",
            "unterminated": payload[:-1],
            "producer-failed": self.payload([*fields[:-1], "7"]),
            "extra-empty": payload + b"\0",
            "extra-field": payload + b"extra\0",
            "count-leading-zero": self.payload([*fields[:3], "02", *fields[4:]]),
            "count-plus": self.payload([*fields[:3], "+2", *fields[4:]]),
            "count-negative": self.payload([*fields[:3], "-1", *fields[4:]]),
            "count-text": self.payload([*fields[:3], "two", *fields[4:]]),
            "count-mismatch": self.payload([*fields[:3], "3", *fields[4:]]),
        }
        for name, raw in malformed.items():
            with self.subTest(case=name):
                self.assertEqual(self.helper(["main", "sites-v1"], raw), (125, b"", b""))
        for args in (
            ["main", "sites-v2"],
            ["unknown", "sites-v1"],
            ["main", "sites-v1", "extra"],
        ):
            with self.subTest(args=args):
                self.assertEqual(self.helper(args, payload), (125, b"", b""))


if __name__ == "__main__":
    unittest.main()
