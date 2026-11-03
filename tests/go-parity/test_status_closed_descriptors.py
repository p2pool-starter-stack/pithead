import json
import os
import subprocess
import unittest

import test_cli
import test_status


class StatusClosedDescriptorParityTest(unittest.TestCase):
    def setUp(self):
        self.fixture = test_status.StatusParityTest(methodName="runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.fixture.model.write_text(json.dumps({}))

    def invoke(self, implementation, descriptor):
        env = self.fixture.child_environment(implementation, self.fixture.env)
        target = os.open(self.fixture.model, os.O_RDONLY)
        try:
            return subprocess.run(  # noqa: S603
                [str(self.fixture.cli), "status"],
                cwd=self.fixture.install,
                env=env,
                stdout=target if descriptor == 1 else subprocess.PIPE,
                stderr=target if descriptor == 2 else subprocess.PIPE,
                timeout=30,
                check=False,
            )
        finally:
            os.close(target)

    def invoke_closed(self, implementation, descriptor):
        env = self.fixture.child_environment(implementation, self.fixture.env)
        return subprocess.run(  # noqa: S603
            [
                test_cli.REAL_BASH,
                "-c",
                f'exec {descriptor}>&-; exec "$@"',
                "closed-descriptor",
                str(self.fixture.cli),
                "status",
            ],
            cwd=self.fixture.install,
            env=env,
            capture_output=True,
            timeout=30,
            check=False,
        )

    def compare(self, descriptor, env_text, expected):
        (self.fixture.install / ".env").write_text(env_text)
        baseline = self.invoke("bash", descriptor)
        native = self.invoke("go", descriptor)
        self.assertEqual(baseline.returncode, expected)
        self.assertEqual(native.returncode, expected)
        if descriptor == 2:
            self.assertEqual(native.stdout, baseline.stdout)
        else:
            self.assertEqual(native.stdout, baseline.stdout)

    def test_unwritable_stdout(self):
        self.compare(1, "", 1)

    def test_unwritable_stderr(self):
        self.compare(2, "MONERO_CLEARNET_SYNC=true\n", 0)

    def test_closed_stdout_uses_reference_path(self):
        (self.fixture.install / ".env").write_text("")
        baseline = self.invoke_closed("bash", 1)
        native = self.invoke_closed("go", 1)
        self.assertEqual(
            (native.returncode, native.stdout, native.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        self.assertEqual(native.returncode, 1)

    def test_closed_stderr_keeps_native_parity(self):
        (self.fixture.install / ".env").write_text("MONERO_CLEARNET_SYNC=true\n")
        baseline = self.invoke_closed("bash", 2)
        native = self.invoke_closed("go", 2)
        self.assertEqual(
            (native.returncode, native.stdout, native.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )

    def test_readwrite_devnull_stays_native(self):
        marker = self.fixture.install / "native-called"
        spy = self.fixture.bin / "pithead-go-spy"
        spy.write_text(f'#!/bin/sh\nprintf called >"{marker}"\nexec "{test_cli.GO_BINARY}" "$@"\n')
        spy.chmod(0o755)
        (self.fixture.install / ".env").write_text("")
        env = self.fixture.child_environment(
            "go", {**self.fixture.env, "PITHEAD_GO_BINARY": str(spy)}
        )
        result = subprocess.run(  # noqa: S603
            [
                test_cli.REAL_BASH,
                "-c",
                'exec 1<>/dev/null; exec "$@"',
                "devnull",
                str(self.fixture.cli),
                "status",
            ],
            cwd=self.fixture.install,
            env=env,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(marker.read_text(), "called")


if __name__ == "__main__":
    unittest.main()
