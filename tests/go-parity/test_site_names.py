import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/site_names_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class SiteNamesParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache"
        cache.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.calls = self.directory / "calls"
        self.traps = self.directory / "traps"
        self.spy_log = self.directory / "spy"

    def environment(self, implementation, case, binary=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            SITE_NAMES_PARITY_IMPL=implementation,
            SITE_NAMES_CALL_LOG=str(self.calls),
            SITE_NAMES_TRAP_LOG=str(self.traps),
            SITE_NAMES_SPY_LOG=str(self.spy_log),
            SITE_NAMES_REAL_GO=str(GO_BINARY),
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            SITE_NAMES_APPLIANCE="true",
            SITE_NAMES_HOSTNAME="rig",
            SITE_NAMES_HOST_IP="rig.local",
            SITE_NAMES_ADDRESSES="",
            SITE_NAMES_BRIDGES="",
            SITE_NAMES_HOSTNAME_RC="0",
            SITE_NAMES_ADDRESSES_RC="0",
            SITE_NAMES_BRIDGES_RC="0",
            DASHBOARD_HOST="",
            DASHBOARD_EXPOSE_PUBLIC_IP="false",
            NETWORK_PREFIX="172.28.0",
            HOST_IP="rig.local",
        )
        env.update(case)
        return env

    def invoke(self, implementation, operation, case, binary=None, files=(), bash_executable=BASH):
        work = (
            self.directory / f"{operation}-{implementation}-{len(list(self.directory.iterdir()))}"
        )
        work.mkdir()
        for name in files:
            (work / name).write_bytes(b"")
        self.calls.write_bytes(b"")
        self.traps.write_bytes(b"")
        self.spy_log.write_bytes(b"")
        completed = subprocess.run(  # noqa: S603
            [bash_executable, str(ADAPTER), str(ROOT), operation],
            cwd=work,
            env=self.environment(implementation, case, binary),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return (
            completed.returncode,
            completed.stdout,
            completed.stderr,
            self.calls.read_bytes(),
            self.traps.read_bytes(),
            self.spy_log.read_bytes(),
        )

    def compare(self, operation, case, binary=None, files=(), native=True, bash_executable=BASH):
        baseline = self.invoke(
            "bash", operation, case, files=files, bash_executable=bash_executable
        )
        selected = self.invoke("go", operation, case, binary, files, bash_executable)
        self.assertEqual(selected[:5], baseline[:5])
        if native:
            self.assertTrue(selected[5])
            self.assertTrue(all(line.endswith(b":0") for line in selected[5].splitlines()))
        return baseline, selected

    def make_spy(self):
        path = self.directory / "go-spy"
        path.write_text(
            "#!/usr/bin/env bash\n"
            "set -Eeuo pipefail\n"
            'if "$SITE_NAMES_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'printf "%s:%s:%s\n" "${PITHEAD_GO_HELPER:-}" "${1:-}" "$rc" '
            '>>"$SITE_NAMES_SPY_LOG"\n'
            'exit "$rc"\n'
        )
        path.chmod(0o755)
        return path

    def make_helper(self, body):
        path = self.directory / f"helper-{len(list(self.directory.iterdir()))}"
        path.write_text("#!/usr/bin/env bash\nset -Eeuo pipefail\n" + body)
        path.chmod(0o755)
        return path

    def test_expansion_and_san_match_with_native_helpers(self):
        spy = self.make_spy()
        cases = {
            "auto-filtered": (
                {
                    "SITE_NAMES_ADDRESSES": (
                        "192.168.1.20 172.19.0.1 172.28.0.1 8.8.8.8 "
                        "fd00:2463::1 2606:4700::1111 192.168.1.20"
                    ),
                    "SITE_NAMES_BRIDGES": "172.19.0.1\n",
                },
                b"rig.local 192.168.1.20 fd00:2463::1 localhost",
                b"DNS:rig.local,IP:192.168.1.20,IP:fd00:2463::1,DNS:localhost",
            ),
            "public-opt-in": (
                {
                    "SITE_NAMES_ADDRESSES": "8.8.8.8 2606:4700::1111",
                    "DASHBOARD_EXPOSE_PUBLIC_IP": "true",
                },
                b"rig.local 8.8.8.8 2606:4700::1111 localhost",
                b"DNS:rig.local,IP:8.8.8.8,IP:2606:4700::1111,DNS:localhost",
            ),
            "label-expands": (
                {"DASHBOARD_HOST": "RIG-2", "HOST_IP": "rig-2", "SITE_NAMES_ADDRESSES": "10.0.0.2"},
                b"rig-2 10.0.0.2 localhost",
                b"DNS:rig-2,IP:10.0.0.2,DNS:localhost",
            ),
            "empty-addresses": ({}, b"rig.local localhost", b"DNS:rig.local,DNS:localhost"),
            "duplicates": (
                {"HOST_IP": "rig.local localhost", "SITE_NAMES_ADDRESSES": "rig.local localhost"},
                b"rig.local localhost",
                b"DNS:rig.local,DNS:localhost",
            ),
        }
        for name, (case, expected_site, expected_san) in cases.items():
            for operation in ("site", "san"):
                with self.subTest(case=name, operation=operation):
                    baseline, selected = self.compare(operation, case, spy)
                    if operation == "site":
                        self.assertEqual(baseline[1], expected_site)
                        self.assertEqual(selected[5].splitlines(), [b"config-site-names:expand:0"])
                    else:
                        self.assertEqual(baseline[1], expected_san)
                        self.assertEqual(
                            selected[5].splitlines(),
                            [b"config-site-names:expand:0", b"config-site-names:san:0"],
                        )

    def test_explicit_pin_diy_and_hostname_fallback_match(self):
        spy = self.make_spy()
        cases = [
            (
                {"DASHBOARD_HOST": "panel.example", "HOST_IP": "panel.example"},
                b"panel.example",
                b"appliance\nappliance\n",
            ),
            (
                {"DASHBOARD_HOST": "auto", "HOST_IP": "rig.local"},
                b"rig.local",
                b"appliance\nappliance\n",
            ),
            (
                {"SITE_NAMES_APPLIANCE": "false", "HOST_IP": "", "SITE_NAMES_HOSTNAME": "diy"},
                b"diy",
                b"appliance\nhostname\nappliance\n",
            ),
            (
                {"HOST_IP": "", "SITE_NAMES_HOSTNAME": "node", "SITE_NAMES_ADDRESSES": "10.0.0.2"},
                b"node.local 10.0.0.2 localhost",
                b"appliance\nhostname\nappliance\nbridges\nhostname:-I\n",
            ),
        ]
        for case, expected, calls in cases:
            with self.subTest(case=case):
                baseline, selected = self.compare("site", case, spy, native=False)
                self.assertEqual(baseline[1], expected)
                self.assertEqual(baseline[3], calls)
                if b"hostname:-I" in calls:
                    self.assertEqual(selected[5], b"config-site-names:expand:0\n")
                else:
                    self.assertEqual(selected[5], b"")

    def test_shell_splitting_globbing_and_literal_dedupe_match(self):
        spy = self.make_spy()
        cases = [
            (
                {"SITE_NAMES_ADDRESSES": "*.site", "DASHBOARD_EXPOSE_PUBLIC_IP": "true"},
                ("b.site", "a.site"),
            ),
            (
                {
                    "SITE_NAMES_IFS": "colon",
                    "SITE_NAMES_ADDRESSES": "fd00:2463::1",
                    "DASHBOARD_EXPOSE_PUBLIC_IP": "true",
                },
                (),
            ),
            (
                {
                    "SITE_NAMES_IFS": "empty",
                    "SITE_NAMES_ADDRESSES": "10.0.0.2 10.0.0.3",
                    "DASHBOARD_EXPOSE_PUBLIC_IP": "true",
                },
                (),
            ),
            (
                {
                    "HOST_IP": "alpha beta",
                    "SITE_NAMES_ADDRESSES": "alpha beta gamma",
                    "DASHBOARD_EXPOSE_PUBLIC_IP": "true",
                },
                (),
            ),
            (
                {
                    "HOST_IP": "alpha\nbeta",
                    "SITE_NAMES_ADDRESSES": "alpha beta",
                    "DASHBOARD_EXPOSE_PUBLIC_IP": "true",
                },
                (),
            ),
        ]
        for case, files in cases:
            for operation in ("site", "san"):
                with self.subTest(case=case, operation=operation):
                    self.compare(operation, case, spy, files)

    def test_refused_missing_and_malformed_helpers_fall_back_once(self):
        helpers = [
            self.directory / "missing",
            self.make_helper("exit 125\n"),
            self.make_helper("printf junk\n"),
            self.make_helper("printf '%s\\0' junk bad\n"),
            self.make_helper("printf '%s\\0' junk 0 extra\n"),
        ]
        case = {
            "SITE_NAMES_ADDRESSES": "10.0.0.2 172.19.0.1",
            "SITE_NAMES_BRIDGES": "172.19.0.1\n",
            "SITE_NAMES_ERR_TRAP": "1",
        }
        for helper in helpers:
            for operation in ("site", "san"):
                with self.subTest(helper=helper.name, operation=operation):
                    baseline, selected = self.compare(operation, case, helper, native=False)
                    self.assertEqual(selected[3].count(b"hostname:-I\n"), 1)
                    self.assertEqual(selected[3].count(b"bridges\n"), 1)
                    self.assertEqual(selected[4], baseline[4])

    def test_unsupported_public_address_falls_back_without_repeating_discovery(self):
        spy = self.make_spy()
        case = {
            "SITE_NAMES_ADDRESSES": "fffffffffffffffff::1 10.0.0.2",
            "SITE_NAMES_ERR_TRAP": "1",
        }
        for operation in ("site", "san"):
            with self.subTest(operation=operation):
                baseline, selected = self.compare(operation, case, spy, native=False)
                self.assertEqual(selected[:5], baseline[:5])
                self.assertEqual(selected[3].count(b"hostname:-I\n"), 1)
                self.assertEqual(selected[3].count(b"bridges\n"), 1)
                self.assertEqual(selected[5].splitlines()[0], b"config-site-names:expand:125")

    def test_partial_nonzero_discovery_output_is_retained(self):
        spy = self.make_spy()
        cases = [
            {"SITE_NAMES_ADDRESSES": "10.0.0.2", "SITE_NAMES_ADDRESSES_RC": "7"},
            {"HOST_IP": "", "SITE_NAMES_HOSTNAME": "partial", "SITE_NAMES_HOSTNAME_RC": "9"},
        ]
        for case in cases:
            for operation in ("site", "san"):
                with self.subTest(case=case, operation=operation):
                    self.compare(operation, case, spy)

    def test_nonzero_bridge_discovery_stops_before_helper(self):
        spy = self.make_spy()
        case = {
            "SITE_NAMES_BRIDGES": "172.19.0.1",
            "SITE_NAMES_BRIDGES_RC": "8",
            "SITE_NAMES_ADDRESSES": "172.19.0.1",
        }
        for operation in ("site", "san"):
            with self.subTest(operation=operation):
                baseline, selected = self.compare(operation, case, spy, native=False)
                if operation == "site":
                    self.assertEqual(baseline[0], 8)
                    self.assertEqual(selected[5], b"")
                else:
                    self.assertEqual(
                        (baseline[0], baseline[1]), (0, b"DNS:rig.local,DNS:localhost")
                    )
                    self.assertEqual(
                        selected[5],
                        b"config-site-names:expand:0\nconfig-site-names:san:0\n",
                    )

    def test_missing_hook_falls_back_silently(self):
        case = {
            "SITE_NAMES_WITHOUT_GO_HOOK": "1",
            "SITE_NAMES_ADDRESSES": "10.0.0.2",
            "SITE_NAMES_ERR_TRAP": "1",
        }
        for operation in ("site", "san"):
            with self.subTest(operation=operation):
                baseline, selected = self.compare(operation, case, native=False)
                self.assertEqual(selected[:5], baseline[:5])
                self.assertEqual(selected[2], b"")

    def test_empty_site_and_san_match_with_system_bash(self):
        spy = self.make_spy()
        case = {
            "SITE_NAMES_APPLIANCE": "false",
            "SITE_NAMES_HOSTNAME_EMPTY": "1",
            "HOST_IP": "",
        }
        for operation in ("site", "san"):
            with self.subTest(operation=operation):
                baseline, selected = self.compare(
                    operation,
                    case,
                    spy,
                    native=operation == "san",
                    bash_executable="/bin/bash",
                )
                self.assertEqual((baseline[0], baseline[1], baseline[2]), (0, b"", b""))
                if operation == "site":
                    self.assertEqual(selected[5], b"")
                else:
                    self.assertEqual(selected[5], b"config-site-names:san:0\n")

    def test_helper_protocol_rejects_bad_frames(self):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env["PITHEAD_GO_HELPER"] = "config-site-names"
        cases = [
            ([], b""),
            (["expand"], b"\0".join((b"base", b" bridges ", b"prefix", b"false", b"0", b"0"))),
            (
                ["expand"],
                b"\0".join((b"base", b" bridges ", b"prefix", b"false", b"1", b"only", b"1", b"")),
            ),
            (
                ["expand"],
                b"\0".join((b"base", b" bridges ", b"prefix", b"false", b"01", b"only", b"0", b"")),
            ),
            (["san"], b"\0".join((b"1", b"host", b"1", b""))),
            (["san"], b"\0".join((b"2", b"host", b"0", b""))),
            (["other"], b"\0".join((b"0", b"0", b""))),
        ]
        for args, payload in cases:
            with self.subTest(args=args, payload=payload):
                completed = subprocess.run(  # noqa: S603
                    [str(GO_BINARY), *args],
                    env=env,
                    input=payload,
                    capture_output=True,
                    check=False,
                    timeout=15,
                )
                self.assertEqual(
                    (completed.returncode, completed.stdout, completed.stderr), (125, b"", b"")
                )


if __name__ == "__main__":
    unittest.main()
