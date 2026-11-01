import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class ConfigDefaultsWiringTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.config = self.directory / "config.json"
        self.config.write_text('{"dashboard":{"host":"tail\\n\\n"}}')
        self.marker = self.directory / "jq-called"
        self.tools = self.directory / "bin"
        self.tools.mkdir()
        stub = self.tools / "jq"
        stub.write_text('#!/bin/sh\nprintf called >"$JQ_MARKER"\nexit 91\n')
        stub.chmod(0o755)

    def environment(self, implementation, forbid_jq=False):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.update(
            PITHEAD_IMPL=implementation,
            PITHEAD_GO_BINARY=str(GO_BINARY),
            CONFIG_FILE=str(self.config),
            DEFAULTS_SOURCE=str(ROOT / "lib/pithead/19a-config-defaults.sh"),
        )
        if forbid_jq:
            env["PATH"] = str(self.tools) + os.pathsep + env.get("PATH", os.defpath)
            env["JQ_MARKER"] = str(self.marker)
        return env

    def invoke(self, implementation, command, *args, forbid_jq=False, data=None):
        return subprocess.run(  # noqa: S603
            [
                BASH,
                "-c",
                'source "$DEFAULTS_SOURCE"; config_platform() { printf diy; }; ' + command,
                "test",
                *args,
            ],
            env=self.environment(implementation, forbid_jq),
            input=data,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def test_supported_operations_do_not_start_jq(self):
        for command in [
            "config_defaults new appliance",
            "default_of .tari.mode legacy",
            "new_install_defaults",
            "config_get .dashboard.host",
            "config_get .local_miner.enabled",
        ]:
            with self.subTest(operation=command.split()[0]):
                baseline = self.invoke("bash", command)
                selected = self.invoke("go", command, forbid_jq=True)
                self.assertEqual(
                    (selected.returncode, selected.stdout, selected.stderr),
                    (baseline.returncode, baseline.stdout, baseline.stderr),
                )
                self.assertEqual(selected.returncode, 0)
                self.assertFalse(self.marker.exists())

    def test_cli_fallback_keeps_native_getter(self):
        reference = self.directory / "reference"
        reference.write_text(
            'source "$DEFAULTS_SOURCE"\nconfig_platform() { printf diy; }\nconfig_get .dashboard.host\n'
        )
        env = self.environment("go", forbid_jq=True)
        env["PITHEAD_GO_REFERENCE"] = str(reference)
        selected = subprocess.run(  # noqa: S603
            [str(GO_BINARY), "unported"], env=env, capture_output=True, check=False, timeout=15
        )
        self.assertEqual(
            (selected.returncode, selected.stdout, selected.stderr), (0, b"tail\n\n\n", b"")
        )
        self.assertFalse(self.marker.exists())

    def test_stdin_config_is_left_for_jq(self):
        for raw in [b'{"dashboard":{"host":"stdin"}}', b'{"dashboard":{"host":1e3}}']:
            baseline = self.invoke("bash", "config_get .dashboard.host -", data=raw)
            selected = self.invoke("go", "config_get .dashboard.host -", data=raw)
            self.assertEqual(
                (selected.returncode, selected.stdout, selected.stderr),
                (baseline.returncode, baseline.stdout, baseline.stderr),
            )

    def test_runtime_table_override_is_used(self):
        table = self.directory / "table.json"
        content = (ROOT / "lib/pithead/19a-config-defaults.sh").read_text()
        runtime = content.split("    cat <<'PITHEAD_DEFAULTS_JSON'\n", 1)[1].split(
            "\nPITHEAD_DEFAULTS_JSON", 1
        )[0]
        table.write_text(runtime.replace('"value":"local"', '"value":"off"'))
        command = (
            'config_defaults_json() { /bin/cat "$OVERRIDE_TABLE"; }; default_of .tari.mode legacy'
        )
        for implementation in ("bash", "go"):
            env = self.environment(implementation)
            env["OVERRIDE_TABLE"] = str(table)
            result = subprocess.run(  # noqa: S603
                [
                    BASH,
                    "-c",
                    'source "$DEFAULTS_SOURCE"; config_platform() { printf diy; }; ' + command,
                ],
                env=env,
                capture_output=True,
                check=False,
                timeout=15,
            )
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"off\n", b""))

    def test_failed_table_producer_does_not_duplicate_output(self):
        command = (
            "set -o pipefail; saved=$(config_defaults_json); "
            'config_defaults_json() { printf "%s" "$saved"; printf "producer failed\\n" >&2; return 17; }; '
            "config_defaults new diy"
        )
        baseline = self.invoke("bash", command)
        selected = self.invoke("go", command)
        self.assertEqual(baseline.returncode, 17)
        self.assertEqual(
            (selected.returncode, selected.stdout, selected.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )

    def test_unchanged_render_fixture_matches_env_goldens(self):
        fixtures = ROOT / "tests/stack/fixtures/config-2.0.0"
        for platform, flag in (("diy", "0"), ("appliance", "1")):
            golden = (fixtures / f"{platform}.env").read_bytes()
            expected = b"".join(
                (
                    b"COMPOSE_PROJECT_NAME=pithead\n"
                    if line.startswith(b"COMPOSE_PROFILES=")
                    else b""
                )
                + line
                for line in golden.splitlines(keepends=True)
            )
            for implementation in ("bash", "go"):
                with self.subTest(platform=platform, implementation=implementation):
                    install = self.directory / f"render-{platform}-{implementation}"
                    install.mkdir()
                    result = subprocess.run(  # noqa: S603
                        [
                            BASH,
                            str(fixtures / "render.sh"),
                            str(ROOT / "pithead"),
                            str(fixtures / "absent.json"),
                            flag,
                        ],
                        cwd=install,
                        env=self.environment(implementation),
                        capture_output=True,
                        check=False,
                        timeout=30,
                    )
                    self.assertEqual(result.returncode, 0, "unchanged render fixture failed")
                    rendered = (
                        (install / ".env").read_bytes().replace(str(install).encode(), b"@ROOT@")
                    )
                    self.assertEqual(
                        rendered, expected, "environment bytes differ from the unchanged golden"
                    )
                    for filename in ("local-miner", "dashboard-host"):
                        self.assertEqual(
                            (install / f"{filename}.txt").read_bytes(),
                            (fixtures / f"{platform}.{filename}").read_bytes(),
                        )


if __name__ == "__main__":
    unittest.main()
