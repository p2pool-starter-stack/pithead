import errno
import json
import os
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

import test_cli as cli_parity

ROOT = Path(__file__).resolve().parents[2]
GO_BINARY = ROOT / "go/bin/pithead"
SOURCE_CLI = ROOT / "pithead"
FIXTURE = ROOT / "tests/go-parity/doctor_fixture.sh"
CACHE_TMP = ROOT / ".go-cache/parity"
MAIN_CALL = '\n    main "$@"\n'


class DoctorJSONParityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not GO_BINARY.is_file():
            raise AssertionError(f"missing Go CLI: {GO_BINARY}; run make go-build")
        if not SOURCE_CLI.is_file():
            raise AssertionError(f"missing generated CLI: {SOURCE_CLI}; run make")
        if shutil.which("jq") is None:
            raise AssertionError("jq is required")
        CACHE_TMP.mkdir(parents=True, exist_ok=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=CACHE_TMP)
        self.install = Path(self.temp.name)
        self.reference_dir = self.install / "path with spaces"
        self.reference_dir.mkdir()
        self.reference = self.reference_dir / "pithead"
        source = SOURCE_CLI.read_text()
        if source.count(MAIN_CALL) != 1 or not source.endswith(MAIN_CALL + "fi\n"):
            raise AssertionError("generated CLI main call changed")
        source = source.replace(
            MAIN_CALL,
            '\n    source "${DOCTOR_FIXTURE_ROOT:?}/tests/go-parity/doctor_fixture.sh"' + MAIN_CALL,
        )
        self.reference.write_text(source)
        self.reference.chmod(0o755)
        (self.reference_dir / "VERSION").write_text("fixture\n")
        self.tmpdir = self.install / "tmp"
        self.tmpdir.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def child_environment(self, implementation, overrides=None):
        environment = cli_parity.CLIParityTest.child_environment(self, implementation, overrides)
        environment.update(
            DOCTOR_FIXTURE_ROOT=str(ROOT),
            TMPDIR=str(self.tmpdir),
        )
        return environment

    def invoke(
        self,
        implementation,
        fixture_case="basic",
        env=None,
        args=None,
        executable=None,
    ):
        overrides = {"DOCTOR_FIXTURE_CASE": fixture_case}
        if env:
            overrides.update(env)
        return subprocess.run(  # noqa: S603
            [str(executable or self.reference), *(args or ("doctor", "--json"))],
            cwd=self.install,
            env=self.child_environment(implementation, overrides),
            capture_output=True,
            check=False,
            shell=False,
            timeout=30,
        )

    def invoke_with_closed_stdout(self, implementation, fixture_case):
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        try:
            process = subprocess.Popen(  # noqa: S603
                [str(self.reference), "doctor", "--json"],
                cwd=self.install,
                env=self.child_environment(implementation, {"DOCTOR_FIXTURE_CASE": fixture_case}),
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

    def assert_parity(self, fixture_case):
        baseline = self.invoke("bash", fixture_case)
        go = self.invoke("go", fixture_case)
        self.assertEqual(
            (go.returncode, go.stdout, go.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        return baseline

    def test_json_bytes_stderr_and_exit(self):
        for fixture_case in ("basic", "malformed", "nonzero"):
            with self.subTest(fixture_case=fixture_case):
                result = self.assert_parity(fixture_case)
                report = json.loads(result.stdout)
                self.assertEqual(list(report), ["version", "exit", "summary", "checks"])
                self.assertEqual(result.returncode, int(report["exit"] != 0))

    def test_malformed_rows_match_jq_contract(self):
        result = self.assert_parity("malformed")
        report = json.loads(result.stdout)
        self.assertEqual(report["summary"], {"ok": 1, "warn": 1, "fail": 0, "info": 1})
        self.assertEqual(
            report["checks"],
            [
                {"id": "id", "status": "ok", "message": "message"},
                {"id": None, "status": "warn", "message": "only-message"},
                {
                    "id": "unicode-id",
                    "status": "info",
                    "message": "<tag>& café \x01",
                },
            ],
        )

    def test_native_formatter_does_not_execute_jq(self):
        baseline = self.invoke("bash")
        stub_dir = self.install / "stub-bin"
        stub_dir.mkdir()
        marker = self.install / "jq-invoked"
        jq = stub_dir / "jq"
        jq.write_text("#!/bin/sh\nprintf 'invoked\\n' >\"$JQ_MARKER\"\nexit 91\n")
        jq.chmod(0o755)
        go = self.invoke(
            "go",
            env={
                "JQ_MARKER": str(marker),
                "PATH": f"{stub_dir}{os.pathsep}{os.environ['PATH']}",
            },
        )
        self.assertEqual(
            (go.returncode, go.stdout, go.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        self.assertFalse(marker.exists())

    def test_probe_context_and_temp_files(self):
        for implementation in ("bash", "go"):
            with self.subTest(implementation=implementation):
                result = self.invoke(implementation)
                self.assertEqual(result.returncode, 0)
                self.assertIn(f"cwd=<{self.reference_dir}>".encode(), result.stderr)
                self.assertIn(f"ref=<{self.reference}>".encode(), result.stderr)
                self.assertEqual(list(self.tmpdir.iterdir()), [])

    def test_probe_reference_runs_once(self):
        marker = self.install / "probe-invocations"
        result = self.invoke("go", env={"DOCTOR_FIXTURE_PROBE_MARKER": str(marker)})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), "probe\n")

    def test_relative_symlink_reference(self):
        link = self.install / "current"
        link.symlink_to(self.reference_dir, target_is_directory=True)
        executable = Path("current/pithead")
        baseline = self.invoke("bash", executable=executable)
        go = self.invoke("go", executable=executable)
        self.assertEqual(
            (go.returncode, go.stdout, go.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        self.assertIn(f"cwd=<{self.reference_dir}>".encode(), go.stderr)
        self.assertIn(b"ref=<current/pithead>", go.stderr)

    def test_version_file_states(self):
        version_file = self.reference_dir / "VERSION"
        states = ((b"custom\n", "custom"), (b" \t9.8.7\r\n", "9.8.7"), (b"", ""))
        for contents, expected in states:
            with self.subTest(contents=contents):
                version_file.write_bytes(contents)
                result = self.assert_parity("basic")
                self.assertEqual(json.loads(result.stdout)["version"], expected)
        version_file.unlink()
        result = self.assert_parity("basic")
        self.assertEqual(json.loads(result.stdout)["version"], "")

    def invoke_with_terminal(self, implementation):
        master, slave = os.openpty()
        process = subprocess.Popen(  # noqa: S603
            [str(self.reference), "doctor", "--json"],
            cwd=self.install,
            env=self.child_environment(
                implementation, {"DOCTOR_FIXTURE_CASE": "basic", "NO_COLOR": ""}
            ),
            stdout=slave,
            stderr=subprocess.PIPE,
            shell=False,
        )
        os.close(slave)
        stdout = bytearray()
        read_errors = []

        def drain_terminal():
            while True:
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        read_errors.append(error)
                    return
                if not chunk:
                    return
                stdout.extend(chunk)

        reader = threading.Thread(target=drain_terminal, daemon=True)
        reader.start()
        try:
            _, stderr = process.communicate(timeout=30)
            reader.join(timeout=30)
            self.assertFalse(reader.is_alive(), "terminal reader did not finish")
            if read_errors:
                raise read_errors[0]
        finally:
            os.close(master)
            if process.poll() is None:
                process.kill()
                process.communicate()
        return process.returncode, bytes(stdout), stderr

    def test_terminal_output_falls_back(self):
        baseline = self.invoke_with_terminal("bash")
        go = self.invoke_with_terminal("go")
        self.assertEqual(go, baseline)
        self.assertIn(b"\x1b[1;32m", go[2])

    def test_missing_jq_falls_back(self):
        utility_dir = self.install / "utilities-without-jq"
        utility_dir.mkdir()
        utilities = ("bash", "uname", "dirname", "basename", "tr", "mktemp", "rm")
        for utility in utilities:
            target = shutil.which(utility)
            if target is None:
                raise AssertionError(f"missing utility: {utility}")
            (utility_dir / utility).symlink_to(target)
        environment = {"PATH": str(utility_dir)}
        baseline = self.invoke("bash", env=environment)
        go = self.invoke("go", env=environment)
        self.assertEqual(
            (go.returncode, go.stdout, go.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        self.assertEqual(go.stdout, b"")

    def test_closed_stdout_behavior(self):
        for fixture_case in ("basic", "nonzero"):
            with self.subTest(fixture_case=fixture_case):
                self.assertEqual(
                    self.invoke_with_closed_stdout("go", fixture_case),
                    self.invoke_with_closed_stdout("bash", fixture_case),
                )

    def test_abrupt_probe_exit_does_not_format_json(self):
        cases = (
            ("abrupt-one", 1),
            ("abrupt-twenty-three", 23),
            ("abrupt-term", -signal.SIGTERM),
        )
        for fixture_case, exit_code in cases:
            with self.subTest(fixture_case=fixture_case):
                baseline = self.invoke("bash", fixture_case)
                go = self.invoke("go", fixture_case)
                self.assertEqual(baseline.returncode, exit_code)
                self.assertEqual(baseline.stdout, b"")
                self.assertEqual(
                    (go.returncode, go.stdout, go.stderr),
                    (baseline.returncode, baseline.stdout, baseline.stderr),
                )

    def invoke_blocking_probe(self, implementation):
        fifo = self.install / f"probe-{implementation}.fifo"
        pid_file = self.install / f"probe-{implementation}.pid"
        os.mkfifo(fifo)
        process = subprocess.Popen(  # noqa: S603
            [str(self.reference), "doctor", "--json"],
            cwd=self.install,
            env=self.child_environment(
                implementation,
                {
                    "DOCTOR_FIXTURE_CASE": "block",
                    "DOCTOR_FIXTURE_FIFO": str(fifo),
                    "DOCTOR_FIXTURE_PID": str(pid_file),
                },
            ),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=False,
        )
        deadline = time.monotonic() + 5
        while not pid_file.exists() and process.poll() is None and time.monotonic() < deadline:
            threading.Event().wait(0.01)
        if not pid_file.exists():
            process.kill()
            process.communicate()
            raise AssertionError("blocking probe did not start")
        probe_pid = int(pid_file.read_text())
        process.send_signal(signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            raise
        try:
            os.kill(probe_pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError(f"probe process survived SIGTERM: {probe_pid}")
        return process.returncode, stdout, stderr

    def test_external_sigterm_reaches_blocking_probe(self):
        baseline = self.invoke_blocking_probe("bash")
        go = self.invoke_blocking_probe("go")
        self.assertEqual(baseline[0], -signal.SIGTERM)
        self.assertEqual(baseline[1], b"")
        self.assertEqual(go, baseline)

    def test_unsupported_arguments_fall_back(self):
        for args in (("doctor",), ("doctor", "--json", "extra")):
            with self.subTest(args=args):
                baseline = self.invoke("bash", args=args)
                go = self.invoke("go", args=args)
                self.assertEqual(
                    (go.returncode, go.stdout, go.stderr),
                    (baseline.returncode, baseline.stdout, baseline.stderr),
                )


if __name__ == "__main__":
    unittest.main()
