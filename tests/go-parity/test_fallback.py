import json
import os
import shlex
import shutil
import subprocess
import unittest

import test_cli


class FallbackContractTest(unittest.TestCase):
    def setUp(self):
        self.fixture = test_cli.CLIParityTest("runTest")
        self.fixture.setUpClass()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.reference = self.fixture.install / "reference"
        self.env = self.fixture.child_environment(
            "go",
            {
                "PITHEAD_GO_REFERENCE": str(self.reference),
                "CONTRACT_VALUE": "spaces\n* $HOME 'quoted'",
                "CONTRACT_EXIT": "37",
            },
        )
        self.reference.write_text(
            "#!/usr/bin/env bash\n"
            "exec python3 -c "
            + shlex.quote(
                "import json,os,sys; "
                "print(json.dumps([sys.argv[1:],os.getcwd(),"
                "{k:v for k,v in os.environ.items() if k != '_'},sys.stdin.read()],sort_keys=True)); "
                "print('reference stderr',file=sys.stderr); "
                "sys.exit(int(os.environ['CONTRACT_EXIT']))"
            )
            + ' "$@"\n'
        )

    def invoke(self, args, native=True, env=None):
        command = [str(test_cli.GO_BINARY)] if native else ["bash", str(self.reference)]
        return subprocess.run(  # noqa: S603
            command + list(args),
            executable=None if native else shutil.which("bash", path=(env or self.env)["PATH"]),
            env=env or self.env,
            cwd=self.fixture.install,
            input=b"stdin\x00bytes\nsecond line\n",
            capture_output=True,
            timeout=15,
            check=False,
        )

    def assertFallback(self, args, env=None):
        baseline = self.invoke(args, False, env)
        actual = self.invoke(args, True, env)
        self.assertEqual(
            (actual.returncode, actual.stdout, actual.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        self.assertEqual(json.loads(actual.stdout)[0], list(args))

    def test_every_other_command_reaches_bash_unchanged(self):
        commands = (
            "setup apply render up down restart tor-recover upgrade logs test-alert "
            "doctor support-bundle reset-dashboard config-reset factory-reset backup "
            "restore uninstall firstboot-wizard load-images local-miner os-update "
            "control-run-pending egress-run-pending egress-status lan-guard-check "
            "onion-client-key rotate-dashboard-onion rotate-secrets render-quadlet unknown"
        )
        for command in commands.split():
            with self.subTest(command=command):
                self.assertFallback((command,))

    def test_flags_chains_and_literal_arguments_reach_bash(self):
        for args in (
            (),
            ("",),
            ("--native-cli", "reference", "help"),
            ("--unknown",),
            ("status", "--json"),
            ("status", "--help"),
            ("help", "--unknown"),
            ("version", "--unknown"),
            ("help", "version"),
            ("unknown", "", "*", "$HOME", "line\nvalue", "space value", "--", "-h"),
        ):
            with self.subTest(args=args):
                self.assertFallback(args)

    def test_fallback_preserves_all_exit_codes(self):
        for code in (0, 1, 37, 126, 127, 200, 201, 241, 255):
            with self.subTest(code=code):
                env = {**self.env, "CONTRACT_EXIT": str(code)}
                self.assertFallback(("unknown",), env)
                self.assertEqual(self.invoke(("unknown",), env=env).returncode, code)

    def test_missing_status_prerequisites_exec_bash(self):
        self.assertFallback(("status",), {**self.env, "PATH": os.defpath, "LC_ALL": "C"})

    def test_unsupported_locale_exec_bash(self):
        self.assertFallback(("status",), {**self.env, "LC_ALL": "pithead_INVALID"})

    def test_fallback_replaces_process(self):
        self.reference.write_text('printf "%s\\n" "$$"\nexit 37\n')
        process = subprocess.Popen(  # noqa: S603
            [str(test_cli.GO_BINARY), "unknown"],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        stdout, stderr = process.communicate(timeout=15)
        self.assertEqual(
            (process.returncode, stdout, stderr), (37, f"{process.pid}\n".encode(), b"")
        )


class LauncherRecoveryTest(unittest.TestCase):
    def setUp(self):
        self.fixture = test_cli.CLIParityTest("runTest")
        self.fixture.setUpClass()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)

    def test_installed_cli_selects_native_by_default(self):
        binary = self.fixture.install / "go/bin/pithead"
        binary.parent.mkdir(parents=True)
        binary.write_text(
            "#!/bin/sh\nprintf 'native help\\n'\nprintf 'pithead-native-v1\\n' >&3\nexit 200\n"
        )
        binary.chmod(0o755)
        env = self.fixture.child_environment("go")
        env.pop("PITHEAD_IMPL")
        env.pop("PITHEAD_GO_BINARY")
        result = subprocess.run(  # noqa: S603
            [str(self.fixture.cli), "help"], env=env, capture_output=True, timeout=15, check=False
        )
        self.assertEqual(
            (result.returncode, result.stdout, result.stderr), (0, b"native help\n", b"")
        )

    def test_native_health_failure_is_not_replayed_in_bash(self):
        binary = self.fixture.install / "native-failure"
        binary.write_text(
            "#!/bin/sh\nprintf 'native health\\n'\nprintf 'attention\\n' >&5\n"
            "printf 'pithead-native-v1\\n' >&3\nexit 201\n"
        )
        binary.chmod(0o755)
        result = self.fixture.invoke("go", "status", env={"PITHEAD_GO_BINARY": str(binary)})
        self.assertEqual(
            (result.returncode, result.stdout, result.stderr),
            (1, b"native health\n", b"attention\n"),
        )

    def test_missing_nonexecutable_and_broken_binaries_use_bash(self):
        binary = self.fixture.install / "broken-go"
        for mode in (
            "missing",
            "nonexecutable",
            "failure",
            "empty",
            "invalid",
            "crash",
            "collision",
        ):
            with self.subTest(mode=mode):
                if mode != "missing":
                    content = {
                        "nonexecutable": b"#!/bin/sh\nexit 200\n",
                        "failure": b"#!/bin/sh\nexit 1\n",
                        "empty": b"#!/bin/sh\nexit 0\n",
                        "invalid": b"\x7fELF\x00invalid\n",
                        "crash": b'#!/bin/sh\nkill -SEGV "$$"\n',
                        "collision": b"#!/bin/sh\nexit 200\n",
                    }[mode]
                    binary.write_bytes(content)
                    binary.chmod(0o644 if mode == "nonexecutable" else 0o755)
                for command in ("help", "version"):
                    baseline = self.fixture.invoke("bash", command)
                    actual = self.fixture.invoke(
                        "go", command, env={"PITHEAD_GO_BINARY": str(binary)}
                    )
                    self.assertEqual(
                        (actual.returncode, actual.stdout, actual.stderr),
                        (baseline.returncode, baseline.stdout, baseline.stderr),
                    )

    def test_extra_arguments_never_enter_native_dispatch(self):
        binary = self.fixture.install / "unexpected-go"
        marker = self.fixture.install / "called"
        binary.write_text(f'#!/bin/sh\nprintf called >"{marker}"\nexit 200\n')
        binary.chmod(0o755)
        for args in (("status", "--help"), ("help", "--unknown"), ("version", "help")):
            with self.subTest(args=args):
                baseline = self.fixture.invoke("bash", *args)
                actual = self.fixture.invoke("go", *args, env={"PITHEAD_GO_BINARY": str(binary)})
                self.assertEqual(
                    (actual.returncode, actual.stdout, actual.stderr),
                    (baseline.returncode, baseline.stdout, baseline.stderr),
                )
                self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
