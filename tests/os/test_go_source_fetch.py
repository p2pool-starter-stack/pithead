import functools
import http.server
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOCKERFILE = Path(os.environ.get("ROOTFS_DOCKERFILE", ROOT / "os/rootfs/Dockerfile"))


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)  # noqa: S603


class SourceFetchTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {
            **os.environ,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
        }
        for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_COUNT"):
            self.env.pop(key, None)
        source = self.root / "upstream"
        run("git", "init", str(source), env=self.env)
        (source / "payload").write_text("pinned source\n")
        run("git", "-C", str(source), "add", ".", env=self.env)
        run(
            "git",
            "-C",
            str(source),
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "-m",
            "fixture",
            env=self.env,
        )
        self.commit = run(
            "git", "-C", str(source), "rev-parse", "HEAD", env=self.env
        ).stdout.strip()
        run("git", "-C", str(source), "tag", "v1", env=self.env)
        self.bare = self.root / "source.git"
        run("git", "clone", "--bare", str(source), str(self.bare), env=self.env)
        run("git", "-C", str(self.bare), "update-server-info", env=self.env)
        self.mode = "healthy"
        self.interruptions = 0
        self.requests = []
        owner = self

        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                owner.requests.append(self.path)
                if owner.mode == "slow":
                    time.sleep(2)
                    self.close_connection = True
                    return
                if "/objects/" in self.path and (
                    owner.mode == "failed"
                    or (owner.mode == "interrupted" and not owner.interruptions)
                ):
                    owner.interruptions += 1
                    self.send_response(200)
                    self.send_header("Content-Length", "4096")
                    self.end_headers()
                    self.wfile.write(b"partial")
                    self.close_connection = True
                    return
                super().do_GET()

        handler = functools.partial(Handler, directory=str(self.root))
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=self.server.serve_forever)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = f"http://127.0.0.1:{self.server.server_port}/source.git"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.sleep_log = self.root / "sleeps"
        self.write_tool("sleep", f'printf "%s\\n" "$1" >> "{self.sleep_log}"\n')
        self.env["PATH"] = str(self.bin) + os.pathsep + os.environ["PATH"]
        self.destination = self.root / "checkout"

    def write_tool(self, name, body):
        tool = self.bin / name
        tool.write_text("#!/bin/sh\nset -eu\n" + body)
        tool.chmod(0o755)

    def fetch(self, tool="cosign", version="v1", commit=None):
        dockerfile = DOCKERFILE.read_text().replace("\\\n", "")
        upstream = "sigstore/cosign" if tool == "cosign" else "docker/compose"
        command = next(
            line[4:]
            for line in dockerfile.splitlines()
            if line.startswith("RUN ") and f"https://github.com/{upstream}" in line
        )
        command = command.split("    && go -C", 1)[0]
        command = command.replace(f"https://github.com/{upstream}", self.url)
        command = command.replace(f"/src/{tool}", str(self.destination))
        command = command.replace(
            "/usr/local/bin/fetch-go-source", str(ROOT / "os/rootfs/fetch-go-source.sh")
        )
        self.env[f"{tool.upper()}_COMMIT"] = commit or self.commit
        self.env[f"{tool.upper()}_VERSION"] = version
        return subprocess.run(  # noqa: S603
            ["/bin/sh", "-eu", "-c", command],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=25,
        )

    def assert_clean_failure(self, result):
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.root.glob("checkout.fetch.*")), [])

    def test_pinned_success_for_both_consumers(self):
        for tool in ("compose", "cosign"):
            with self.subTest(tool=tool):
                result = self.fetch(tool)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    run("git", "-C", str(self.destination), "rev-parse", "HEAD").stdout.strip(),
                    self.commit,
                )
                self.assertEqual(
                    run(
                        "git", "-C", str(self.destination), "config", "http.version"
                    ).stdout.strip(),
                    "HTTP/1.1",
                )
                self.assertEqual((self.destination / "payload").read_text(), "pinned source\n")
                self.assertIn("attempt 1/3 (180s deadline)", result.stderr)
                self.assertNotIn("attempt 2/3", result.stderr)
                shutil.rmtree(self.destination)
        self.assertFalse(self.sleep_log.exists())

    def test_interrupted_transfer_recovers_cleanly(self):
        self.mode = "interrupted"
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.interruptions, 1)
        self.assertIn("attempt 2/3", result.stderr)
        self.assertEqual(self.sleep_log.read_text(), "5\n")
        self.assertEqual((self.destination / "payload").read_text(), "pinned source\n")

    def test_repeated_transfer_failure_is_not_success(self):
        self.mode = "failed"
        result = self.fetch()
        self.assert_clean_failure(result)
        self.assertEqual(result.stderr.count("(180s deadline)"), 3)
        self.assertIn("Source fetch exhausted after 3 attempts", result.stderr)
        self.assertEqual(self.sleep_log.read_text(), "5\n10\n")

    def shorten_deadline(self):
        real_timeout = shutil.which("timeout")
        self.assertIsNotNone(real_timeout)
        self.write_tool(
            "timeout",
            f'[ "$1" = --kill-after=5s ]\n[ "$2" = 180s ]\nshift 2\nexec "{real_timeout}" --kill-after=1s 1s "$@"\n',
        )

    def test_attempt_deadline_is_enforced(self):
        self.shorten_deadline()
        self.mode = "slow"
        started = time.monotonic()
        result = self.fetch()
        self.assert_clean_failure(result)
        self.assertLess(time.monotonic() - started, 10)
        self.assertEqual(result.stderr.count("failed (exit 124)"), 3)
        self.assertEqual(self.sleep_log.read_text(), "5\n10\n")

    def test_wrong_tag_fails_without_retry(self):
        result = self.fetch(version="v2")
        self.assert_clean_failure(result)
        self.assertIn("Source pin mismatch", result.stderr)
        self.assertNotIn("attempt 2/3", result.stderr)
        self.assertFalse(self.sleep_log.exists())

    def test_unavailable_commit_fails_after_bounded_attempts(self):
        self.shorten_deadline()
        result = self.fetch(commit="f" * 40)
        self.assert_clean_failure(result)
        self.assertIn("Source fetch exhausted after 3 attempts", result.stderr)
        self.assertEqual(self.sleep_log.read_text(), "5\n10\n")

    def test_dockerfile_copies_helper_before_fetch(self):
        dockerfile = DOCKERFILE.read_text()
        copied = dockerfile.index(
            "COPY os/rootfs/fetch-go-source.sh /usr/local/bin/fetch-go-source"
        )
        self.assertLess(copied, dockerfile.index("RUN sh /usr/local/bin/fetch-go-source"))


if __name__ == "__main__":
    unittest.main()
