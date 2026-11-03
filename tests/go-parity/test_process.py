import fcntl
import json
import os
import select
import signal
import subprocess
import time
import unittest

import test_status


class ProcessParityTest(unittest.TestCase):
    def setUp(self):
        self.fixture = test_status.StatusParityTest("runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        (self.fixture.install / ".env").write_text("COMPOSE_PROFILES=\n")

    def wait_for(self, path, process):
        deadline = time.monotonic() + 10
        while not path.exists() and time.monotonic() < deadline:
            if process is not None:
                self.assertIsNone(process.poll(), "launcher exited before the fixture was ready")
            time.sleep(0.01)
        self.assertTrue(path.exists(), "fixture did not become ready")

    def launch(self, implementation, stdout, stderr, *args):
        return subprocess.Popen(  # noqa: S603
            [str(self.fixture.cli), *(args or ("status",))],
            cwd=self.fixture.install,
            env=self.fixture.child_environment(implementation, self.fixture.env),
            stdout=stdout,
            stderr=stderr,
        )

    def test_lingering_descendant_cannot_hold_launcher_descriptors(self):
        child = self.fixture.install / "descendant.py"
        marker = self.fixture.install / "descendant.json"
        release = self.fixture.install / "release"
        child.write_text(
            "import json,os,time\nfrom pathlib import Path\n"
            "fds=[]\n"
            "for fd in (3,4,5):\n"
            " try: os.fstat(fd); fds.append(fd)\n"
            " except OSError: pass\n"
            f"marker=Path({str(marker)!r})\n"
            "pending=marker.with_suffix('.pending')\n"
            "pending.write_text(json.dumps([os.getpid(),fds]))\n"
            "pending.replace(marker)\n"
            "deadline=time.monotonic()+15\n"
            f"while not Path({str(release)!r}).exists() and time.monotonic()<deadline: time.sleep(0.01)\n"
        )
        self.fixture.model.write_text(json.dumps({"descendant": str(child)}))
        results = []
        for implementation in ("bash", "go"):
            with self.subTest(implementation=implementation):
                marker.unlink(missing_ok=True)
                release.unlink(missing_ok=True)
                with (
                    (self.fixture.install / "stdout").open("wb+") as stdout,
                    (self.fixture.install / "stderr").open("wb+") as stderr,
                ):
                    process = self.launch(implementation, stdout, stderr)
                    child_pid = None
                    try:
                        self.wait_for(marker, None)
                        child_pid, descriptors = json.loads(marker.read_text())
                        process.wait(timeout=5)
                        os.kill(child_pid, 0)
                        self.assertEqual(descriptors, [])
                        stdout.seek(0)
                        stderr.seek(0)
                        results.append((process.returncode, stdout.read(), stderr.read()))
                    finally:
                        release.touch()
                        if child_pid is not None:
                            try:
                                os.kill(child_pid, signal.SIGTERM)
                            except ProcessLookupError:
                                pass
                        if process.poll() is None:
                            process.kill()
                        process.wait(timeout=10)
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0], results[1])

    def test_term_and_int_delivered_to_wrapper_match_bash(self):
        for signum in (signal.SIGTERM, signal.SIGINT):
            results = []
            for implementation in ("bash", "go"):
                with self.subTest(signum=signum, implementation=implementation):
                    ready = self.fixture.install / f"ready-{signum}-{implementation}"
                    release = self.fixture.install / f"release-{signum}-{implementation}"
                    self.fixture.model.write_text(
                        json.dumps({"ready": str(ready), "release": str(release)})
                    )
                    with (
                        (self.fixture.install / "stdout").open("wb+") as stdout,
                        (self.fixture.install / "stderr").open("wb+") as stderr,
                    ):
                        process = self.launch(implementation, stdout, stderr)
                        try:
                            self.wait_for(ready, process)
                            process.send_signal(signum)
                            release.touch()
                            process.wait(timeout=10)
                            results.append(process.returncode)
                        finally:
                            release.touch()
                            if process.poll() is None:
                                process.kill()
                            process.wait(timeout=10)
            self.assertEqual(results[0], results[1], f"signal {signum}")

    def test_process_group_interrupt_never_replays_status(self):
        for implementation in ("bash", "go"):
            with self.subTest(implementation=implementation):
                ready = self.fixture.install / f"ready-{implementation}"
                release = self.fixture.install / f"release-{implementation}"
                invocations = self.fixture.install / f"invocations-{implementation}"
                self.fixture.model.write_text(
                    json.dumps(
                        {
                            "ready": str(ready),
                            "release": str(release),
                            "invocations": str(invocations),
                        }
                    )
                )
                with subprocess.Popen(  # noqa: S603
                    [str(self.fixture.cli), "status"],
                    cwd=self.fixture.install,
                    env=self.fixture.child_environment(implementation, self.fixture.env),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                ) as process:
                    try:
                        self.wait_for(ready, process)
                        os.killpg(process.pid, signal.SIGINT)
                        release.touch()
                        self.assertEqual(process.wait(timeout=10), -signal.SIGINT)
                        self.assertEqual(invocations.read_text(), "1")
                    finally:
                        release.touch()
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait(timeout=10)

    def test_ignored_sigpipe_and_early_closing_consumer(self):
        self.fixture.model.write_text(json.dumps({"table": "fixture " * 16384}))
        driver = self.fixture.install / "ignore-pipe"
        driver.write_text('#!/usr/bin/env bash\ntrap "" PIPE\nexec "$@"\n')
        driver.chmod(0o755)
        for command in ("help", "status"):
            for ignored in (False, True):
                for early in (False, True):
                    self.assert_pipe_parity(command, ignored, early, driver)

    def assert_pipe_parity(self, command, ignored, early, driver):
        results = []
        for implementation in ("bash", "go"):
            with self.subTest(
                command=command, ignored=ignored, early=early, implementation=implementation
            ):
                reader, writer = os.pipe()
                if hasattr(fcntl, "F_SETPIPE_SZ"):
                    fcntl.fcntl(writer, fcntl.F_SETPIPE_SZ, 4096)
                if not early:
                    os.close(reader)
                args = [str(self.fixture.cli), command]
                if ignored:
                    args.insert(0, str(driver))
                try:
                    process = subprocess.Popen(  # noqa: S603
                        args,
                        cwd=self.fixture.install,
                        env=self.fixture.child_environment(implementation, self.fixture.env),
                        stdout=writer,
                        stderr=subprocess.PIPE,
                    )
                finally:
                    os.close(writer)
                if early:
                    self.assertTrue(
                        select.select([reader], [], [], 10)[0], "consumer saw no output"
                    )
                    self.assertTrue(os.read(reader, 1))
                    os.close(reader)
                try:
                    _, stderr = process.communicate(timeout=15)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()
                results.append((process.returncode, stderr))
        self.assertEqual(len(results), 2)
        self.assertEqual(
            results[0], results[1], f"command={command}, ignored={ignored}, early={early}"
        )


if __name__ == "__main__":
    unittest.main()
