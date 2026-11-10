import functools
import http.server
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOCKERFILE = Path(os.environ.get("ROOTFS_DOCKERFILE", ROOT / "os/rootfs/Dockerfile"))
RELEASE_DOCKERFILES = (
    (ROOT / "build/p2pool/Dockerfile", "p2pool.tar.gz"),
    (ROOT / "build/xmrig-proxy/Dockerfile", "xmrig-proxy.tar.gz"),
)
PAYLOAD = b"archive bytes\n"


class FetchTestBase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.served = self.root / "served"
        self.served.mkdir()
        (self.served / "payload.bin").write_bytes(PAYLOAD)
        self.mode = "healthy"
        self.interruptions = 0
        self.release = threading.Event()
        self.requests = []
        owner = self

        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                owner.requests.append(self.path)
                if owner.mode == "slow":
                    owner.release.wait(60)
                    self.close_connection = True
                    return
                transient = owner.mode == "transient" and not owner.interruptions
                if owner.mode == "failed" or transient:
                    owner.interruptions += 1
                    self.send_response(504)
                    self.end_headers()
                    self.wfile.write(b"Gateway Time-out\n")
                    return
                super().do_GET()

        handler = functools.partial(Handler, directory=str(self.served))
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=self.server.serve_forever)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.release.set)
        self.url = f"http://127.0.0.1:{self.server.server_port}/payload.bin"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.sleep_log = self.root / "sleeps"
        self.write_tool("sleep", f'printf "%s\\n" "$1" >> "{self.sleep_log}"\n')
        self.env = {
            key: value
            for key, value in os.environ.items()
            if key.lower() not in ("http_proxy", "https_proxy", "all_proxy")
        }
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]

    def write_tool(self, name, body):
        tool = self.bin / name
        tool.write_text("#!/bin/sh\nset -eu\n" + body)
        tool.chmod(0o755)

    def shorten_deadline(self):
        real_timeout = shutil.which("timeout")
        self.assertIsNotNone(real_timeout)
        self.write_tool(
            "timeout",
            f'[ "$1" = --kill-after=5s ]\n[ "$2" = 180s ]\nshift 2\n'
            f'exec "{real_timeout}" --kill-after=5s 1s "$@"\n',
        )

    def reset(self, mode):
        self.mode = mode
        self.interruptions = 0
        self.requests.clear()

    def assert_clean_failure(self, destination, result):
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.root.glob("destination*")), [])


class ArchiveLayerFetchTest(FetchTestBase):
    def fetch(self):
        dockerfile = DOCKERFILE.read_text().replace("\\\n", "")
        command = next(
            line[4:]
            for line in dockerfile.splitlines()
            if line.startswith("RUN sh /usr/local/bin/fetch-archive")
        )
        command = command.split("    && mkdir -p /opt/rigforge", 1)[0]
        command = command.replace(
            '"https://github.com/p2pool-starter-stack/rigforge/archive/${RIGFORGE_REF}.tar.gz"',
            f'"{self.url}"',
        )
        command = command.replace(
            "/usr/local/bin/fetch-archive", str(ROOT / "os/rootfs/fetch-archive.sh")
        )
        destination = self.root / "destination.bin"
        command = command.replace("/tmp/rigforge.tar.gz", str(destination))  # noqa: S108
        result = subprocess.run(  # noqa: S603
            ["/bin/sh", "-eu", "-c", command],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=25,
        )
        return destination, result

    def test_healthy_fetch_succeeds_first_attempt(self):
        self.reset("healthy")
        destination, result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(destination.read_bytes(), PAYLOAD)
        self.assertEqual(len(self.requests), 1)
        self.assertIn("attempt 1/3 (180s deadline)", result.stderr)
        self.assertNotIn("attempt 2/3", result.stderr)
        self.assertFalse(self.sleep_log.exists())

    def test_transient_5xx_recovers_cleanly(self):
        self.reset("transient")
        destination, result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 2)
        self.assertEqual(destination.read_bytes(), PAYLOAD)
        self.assertIn("attempt 2/3", result.stderr)
        self.assertIn("failed (exit 22, status 504)", result.stderr)
        self.assertEqual(self.sleep_log.read_text(), "5\n")

    def test_persistent_5xx_fails_after_bounded_attempts(self):
        self.reset("failed")
        destination, result = self.fetch()
        self.assert_clean_failure(destination, result)
        self.assertEqual(len(self.requests), 3)
        self.assertEqual(result.stderr.count("(180s deadline)"), 3)
        self.assertIn(f"exhausted after 3 attempts: {self.url} (final status 504)", result.stderr)
        self.assertEqual(self.sleep_log.read_text(), "5\n10\n")

    def test_attempt_deadline_is_enforced(self):
        self.shorten_deadline()
        self.reset("slow")
        started = time.monotonic()
        destination, result = self.fetch()
        self.assert_clean_failure(destination, result)
        self.assertLess(time.monotonic() - started, 20)
        self.assertEqual(result.stderr.count("failed (exit 124, status 000)"), 3)
        self.assertEqual(self.sleep_log.read_text(), "5\n10\n")

    def test_dockerfile_copies_helper_before_fetch(self):
        dockerfile = DOCKERFILE.read_text()
        copied = dockerfile.index("COPY os/rootfs/fetch-archive.sh /usr/local/bin/fetch-archive")
        self.assertLess(copied, dockerfile.index("RUN sh /usr/local/bin/fetch-archive"))


@unittest.skipUnless(shutil.which("wget"), "needs GNU wget on PATH")
class ReleaseWgetFetchTest(FetchTestBase):
    def wget(self, dockerfile, artifact):
        text = Path(dockerfile).read_text().replace("\\\n", "")
        line = next(
            line[4:]
            for line in text.splitlines()
            if line.startswith("RUN wget") and artifact in line
        )
        command = re.sub(r"https://\S+", self.url, line.split("    && echo", 1)[0])
        workdir = self.root / "workdir"
        workdir.mkdir(exist_ok=True)
        result = subprocess.run(  # noqa: S603
            ["/bin/sh", "-eu", "-c", command],
            env=self.env,
            cwd=workdir,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return workdir / artifact, result

    def test_release_fetch_bounds_the_attempts(self):
        for dockerfile, artifact in RELEASE_DOCKERFILES:
            for mode, attempts in (("healthy", 1), ("transient", 2), ("failed", 3)):
                with self.subTest(artifact=artifact, mode=mode):
                    self.reset(mode)
                    artifact_path, result = self.wget(dockerfile, artifact)
                    self.assertEqual(len(self.requests), attempts, result.stderr)
                    if attempts < 3:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(artifact_path.read_bytes(), PAYLOAD)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                    artifact_path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
