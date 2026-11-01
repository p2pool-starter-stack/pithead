import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE_CLI = ROOT / "pithead"
GO_BINARY = Path(os.environ.get("PITHEAD_TEST_GO_BINARY", ROOT / "go/bin/pithead"))
CACHE_TMP = ROOT / ".go-cache/parity"


class FallbackSignalParityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not SOURCE_CLI.is_file() or not GO_BINARY.is_file():
            raise AssertionError("run make and make go-build first")
        CACHE_TMP.mkdir(parents=True, exist_ok=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=CACHE_TMP)
        self.install = Path(self.temp.name)
        self.cli = self.install / "pithead"
        shutil.copy2(SOURCE_CLI, self.cli)
        shutil.copy2(ROOT / "VERSION", self.install / "VERSION")
        self.adapter = self.install / "signal-env.sh"
        self.adapter.write_text(
            'if [ "${PITHEAD_IMPL:-}" = bash ]; then\n'
            '    [ -z "${_PITHEAD_GO_IGNORED_SIGNALS+x}" ] || exit 90\n'
            '    if [ "$SIGNAL_CASE" = pipe ]; then\n'
            "        printf 'closed output\\n'\n"
            "        exit $?\n"
            "    fi\n"
            '    kill -TERM "$$"\n'
            "    printf 'term ignored\\n'\n"
            "    exit 0\n"
            "fi\n"
        )
        self.driver = self.install / "signal-driver.sh"
        self.driver.write_text(
            "#!/usr/bin/env bash\n"
            "trap '' PIPE TERM\n"
            'export BASH_ENV="$SIGNAL_BASH_ENV"\n'
            'exec "$PITHEAD_SIGNAL_CLI" unknown\n'
        )
        self.driver.chmod(0o755)

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, implementation, case):
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("PITHEAD_") and key != "BASH_ENV"
        }
        env.update(
            NO_COLOR="1",
            PITHEAD_GO_BINARY=str(GO_BINARY),
            PITHEAD_IMPL=implementation,
            SIGNAL_BASH_ENV=str(self.adapter),
            PITHEAD_SIGNAL_CLI=str(self.cli),
            SIGNAL_CASE=case,
        )
        if case == "pipe":
            read_fd, write_fd = os.pipe()
            os.close(read_fd)
            try:
                process = subprocess.Popen(  # noqa: S603
                    [str(self.driver)],
                    cwd=self.install,
                    env=env,
                    stdout=write_fd,
                    stderr=subprocess.PIPE,
                )
            finally:
                os.close(write_fd)
            _, stderr = process.communicate(timeout=30)
            return process.returncode, b"", stderr
        result = subprocess.run(  # noqa: S603
            [str(self.driver)],
            cwd=self.install,
            env=env,
            capture_output=True,
            check=False,
            timeout=30,
        )
        return result.returncode, result.stdout, result.stderr

    def test_ignored_sigpipe_is_preserved(self):
        baseline = self.invoke("bash", "pipe")
        self.assertEqual(baseline[0], 1)
        self.assertEqual(self.invoke("go", "pipe"), baseline)

    def test_ignored_sigterm_is_preserved(self):
        baseline = self.invoke("bash", "term")
        self.assertEqual(baseline, (0, b"term ignored\n", b""))
        self.assertEqual(self.invoke("go", "term"), baseline)


if __name__ == "__main__":
    unittest.main()
