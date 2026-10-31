import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GO_BINARY = ROOT / "go/bin/pithead"
SOURCE_CLI = ROOT / "pithead"
REAL_BASH = shutil.which("bash")
CACHE_TMP = ROOT / ".go-cache/parity"
BASH_ENV_ADAPTER = (ROOT / "tests/go-parity/env.sh").resolve()


class CLIParityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not SOURCE_CLI.is_file():
            raise AssertionError(f"missing generated CLI: {SOURCE_CLI}; run make")
        if not GO_BINARY.is_file():
            raise AssertionError(f"missing Go CLI: {GO_BINARY}; run make go-build")
        if REAL_BASH is None:
            raise AssertionError("bash is required")
        CACHE_TMP.mkdir(parents=True, exist_ok=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=CACHE_TMP)
        self.install = Path(self.temp.name)
        self.cli = self.install / "pithead"
        shutil.copy2(SOURCE_CLI, self.cli)
        shutil.copy2(ROOT / "VERSION", self.install / "VERSION")

    def tearDown(self):
        self.temp.cleanup()

    def child_environment(self, implementation, overrides=None):
        child_env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("PITHEAD_") and key != "BASH_ENV"
        }
        inherited_bash_env = os.environ.get("BASH_ENV")
        if inherited_bash_env and Path(inherited_bash_env).resolve() == BASH_ENV_ADAPTER:
            child_env["BASH_ENV"] = inherited_bash_env
        child_env.update(
            NO_COLOR="1",
            PITHEAD_IMPL=implementation,
            PITHEAD_GO_BINARY=str(GO_BINARY),
        )
        if overrides:
            child_env.update(overrides)
        return child_env

    def invoke(self, implementation, *args, env=None, executable=None):
        command = [str(executable or self.cli), *args]
        return subprocess.run(  # noqa: S603
            command,
            cwd=self.install,
            env=self.child_environment(implementation, env),
            capture_output=True,
            check=False,
            shell=False,
            timeout=30,
        )

    def invoke_with_closed_stdout(self, implementation, *args):
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        try:
            process = subprocess.Popen(  # noqa: S603
                [str(self.cli), *args],
                cwd=self.install,
                env=self.child_environment(implementation),
                stdout=write_fd,
                stderr=subprocess.PIPE,
                shell=False,
            )
        finally:
            os.close(write_fd)
        try:
            _, stderr = process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            raise
        return process.returncode, stderr

    def assertParity(self, *args):
        baseline = self.invoke("bash", *args)
        go = self.invoke("go", *args)
        self.assertEqual(
            (go.returncode, go.stdout, go.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )

    def test_help_aliases(self):
        for args in (("help",), ("-h",), ("--help",)):
            with self.subTest(args=args):
                self.assertParity(*args)

    def test_version_aliases(self):
        for args in (("version",), ("-V",), ("--version",)):
            with self.subTest(args=args):
                self.assertParity(*args)

    def test_closed_stdout_signal_behavior(self):
        for args in (("help",), ("version",)):
            with self.subTest(args=args):
                self.assertEqual(
                    self.invoke_with_closed_stdout("go", *args),
                    self.invoke_with_closed_stdout("bash", *args),
                )

    def test_subcommand_help(self):
        for args in (
            ("status", "--help"),
            ("unknown", "--help"),
            ("version", "-h"),
        ):
            with self.subTest(args=args):
                self.assertParity(*args)

    def test_help_and_version_ignore_extra_arguments(self):
        for args in (
            ("help", "ignored", "--literal"),
            ("version", "ignored", "--literal"),
        ):
            with self.subTest(args=args):
                self.assertParity(*args)

    def test_chain_dispatch_takes_precedence(self):
        self.assertParity("version", "help")

    def test_logs_help_passes_through(self):
        self.assertParity("logs", "--help")

    def test_unported_failures_fall_back(self):
        for args in (
            ("status",),
            ("status", "--json"),
            ("doctor", "--not-an-option"),
            ("unknown", "--literal=$DOCS_URL", "*", "space value"),
        ):
            with self.subTest(args=args):
                self.assertParity(*args)

    def test_version_states(self):
        states = (
            ("release", "9.9.9\n", False),
            ("whitespace", " \t\r\n", False),
            ("missing", None, False),
            ("dev", "9.9.9\n", True),
        )
        for name, version, dev in states:
            with self.subTest(name=name):
                version_file = self.install / "VERSION"
                if version is None:
                    version_file.unlink(missing_ok=True)
                else:
                    version_file.write_text(version)
                dashboard = self.install / "dashboard"
                if dev:
                    dashboard.mkdir(exist_ok=True)
                    shutil.copy2(ROOT / "dashboard/Dockerfile", dashboard / "Dockerfile")
                else:
                    shutil.rmtree(dashboard, ignore_errors=True)
                self.assertParity("version")

    def test_native_commands_do_not_spawn_bash(self):
        stub_bin = self.install / "stub-bin"
        stub_bin.mkdir()
        stub = stub_bin / "bash"
        stub.write_text("#!/bin/sh\necho fallback-bash-invoked >&2\nexit 91\n")
        stub.chmod(0o755)
        restricted_path = f"{stub_bin}{os.pathsep}{os.defpath}"

        for args in (("help",), ("version",)):
            with self.subTest(args=args):
                normal = self.invoke("go", *args)
                direct = subprocess.run(  # noqa: S603
                    [REAL_BASH, str(self.cli), *args],
                    cwd=self.install,
                    env=self.child_environment("go", {"PATH": restricted_path}),
                    capture_output=True,
                    check=False,
                    shell=False,
                    timeout=30,
                )
                self.assertEqual(
                    (direct.returncode, direct.stdout, direct.stderr),
                    (normal.returncode, normal.stdout, normal.stderr),
                )

        fallback = subprocess.run(  # noqa: S603
            [REAL_BASH, str(self.cli), "logs", "--help"],
            cwd=self.install,
            env=self.child_environment("go", {"PATH": restricted_path}),
            capture_output=True,
            check=False,
            shell=False,
            timeout=30,
        )
        self.assertEqual(fallback.returncode, 91)
        self.assertEqual(fallback.stderr, b"fallback-bash-invoked\n")

    def test_fallback_preserves_literal_arguments_and_exit_status(self):
        reference = self.install / "reference"
        reference.write_text(
            "#!/usr/bin/env bash\n"
            "printf 'impl=<%s>\\n' \"${PITHEAD_IMPL-}\"\n"
            "printf 'arg=<%s>\\n' \"$@\"\n"
            "exit 37\n"
        )
        reference.chmod(0o755)
        args = ("unknown", "--literal=$DOCS_URL", "*", "space value")
        result = self.invoke(
            "go",
            *args,
            env={"PITHEAD_GO_REFERENCE": str(reference)},
            executable=GO_BINARY,
        )
        self.assertEqual(result.returncode, 37)
        self.assertEqual(
            result.stdout,
            b"impl=<bash>\narg=<unknown>\narg=<--literal=$DOCS_URL>\narg=<*>\narg=<space value>\n",
        )
        self.assertEqual(result.stderr, b"")

    def test_fallback_preserves_signal_and_fd9(self):
        marker = self.install / "fd9-marker"
        reference = self.install / "signal-reference"
        reference.write_text(
            "#!/usr/bin/env bash\nprintf 'fd9 inherited\\n' >&9 || exit 88\nkill -TERM \"$$\"\n"
        )
        reference.chmod(0o755)
        driver = self.install / "signal-driver"
        driver.write_text(
            '#!/usr/bin/env bash\nexec 9>"$MARKER"\nexec "$PITHEAD_GO_BINARY" unknown\n'
        )
        driver.chmod(0o755)
        result = self.invoke(
            "go",
            env={
                "MARKER": str(marker),
                "PITHEAD_GO_REFERENCE": str(reference),
            },
            executable=driver,
        )
        self.assertEqual(result.returncode, -15)
        self.assertEqual(marker.read_text(), "fd9 inherited\n")


if __name__ == "__main__":
    unittest.main()
