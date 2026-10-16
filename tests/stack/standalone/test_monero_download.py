import hashlib
import http.server
import os
import re
import shlex
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DOWNLOADER = ROOT / "build/monero/download.sh"
PAYLOAD = b"pinned Monero archive fixture\n"
HASH = hashlib.sha256(PAYLOAD).hexdigest()


class DownloadHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.server.requests.append(self.path)
        if self.path == "/missing":
            self.send_error(404)
            return
        if self.path == "/downgrade":
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{self.server.server_port}/good")
            self.end_headers()
            return
        payload = PAYLOAD if self.path == "/good" else b"wrong archive"
        self.send_response(200)
        self.send_header("Content-Length", str(10000 if self.path == "/slow" else len(payload)))
        self.end_headers()
        try:
            if self.path == "/slow":
                for _ in range(100):
                    self.wfile.write(b"x")
                    self.wfile.flush()
                    if self.server.stopping.wait(0.05):
                        break
            else:
                self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass


class MoneroDownloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.scratch.cleanup)
        cls.cert = Path(cls.scratch.name) / "cert.pem"
        key = Path(cls.scratch.name) / "key.pem"
        subprocess.run(  # noqa: S603
            [  # noqa: S607
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-subj",
                "/CN=localhost",
                "-addext",
                "subjectAltName=DNS:localhost",
                "-keyout",
                str(key),
                "-out",
                str(cls.cert),
            ],
            check=True,
            capture_output=True,
            timeout=15,
        )

    def setUp(self):
        self.work = tempfile.TemporaryDirectory(dir=self.scratch.name)
        self.addCleanup(self.work.cleanup)
        self.output = Path(self.work.name) / "monero.tar.bz2"
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), DownloadHandler)
        self.server.daemon_threads = False
        self.server.requests = []
        self.server.stopping = threading.Event()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(self.cert, Path(self.scratch.name) / "key.pem")
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.server.stopping.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.assertFalse(self.thread.is_alive())

    def download(self, primary, fallback):
        base = f"https://localhost:{self.server.server_port}"
        env = dict(
            os.environ, CURL_CA_BUNDLE=str(self.cert), NO_PROXY="localhost", no_proxy="localhost"
        )
        started = time.monotonic()
        result = subprocess.run(  # noqa: S603
            ["sh", str(DOWNLOADER), HASH, "0.7", str(self.output), base + primary, base + fallback],  # noqa: S607
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertFalse(Path(str(self.output) + ".part").exists())
        return result, time.monotonic() - started

    def test_primary_success_does_not_request_fallback(self):
        result, _ = self.download("/good", "/bad")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_bytes(), PAYLOAD)
        self.assertEqual(self.server.requests, ["/good"])

    def test_continuously_slow_primary_recovers_using_fallback(self):
        result, elapsed = self.download("/slow", "/good")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_bytes(), PAYLOAD)
        self.assertEqual(self.server.requests, ["/slow", "/good"])
        self.assertGreaterEqual(elapsed, 0.6)
        self.assertLess(elapsed, 4)
        self.assertIn("source transfer failed", result.stderr)

    def test_http_failure_recovers_using_fallback(self):
        result, _ = self.download("/missing", "/good")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_bytes(), PAYLOAD)
        self.assertEqual(self.server.requests, ["/missing", "/good"])

    def test_primary_checksum_mismatch_stops_without_fallback(self):
        result, _ = self.download("/bad", "/good")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertIn("SHA-256 verification failed", result.stderr)
        self.assertEqual(self.server.requests, ["/bad"])

    def test_fallback_checksum_mismatch_is_rejected(self):
        result, _ = self.download("/missing", "/bad")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertIn("SHA-256 verification failed", result.stderr)
        self.assertEqual(self.server.requests, ["/missing", "/bad"])

    def test_continuously_slow_sources_exhaust_bounded_budget(self):
        result, elapsed = self.download("/slow", "/slow")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertIn("all sources failed", result.stderr)
        self.assertEqual(self.server.requests, ["/slow", "/slow"])
        self.assertGreaterEqual(elapsed, 1.2)
        self.assertLess(elapsed, 4)

    def test_http_downgrade_is_not_followed(self):
        result, _ = self.download("/downgrade", "/missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.server.requests, ["/downgrade", "/missing"])

    def test_dockerfile_wires_two_versioned_sources_and_ten_minute_budget(self):
        dockerfile = (ROOT / "build/monero/Dockerfile").read_text().replace("\\\n", " ")
        self.assertIn("COPY download.sh /usr/local/bin/download-monero", dockerfile)
        command = re.search(
            r"^RUN sh /usr/local/bin/download-monero (.*?)&& tar ", dockerfile, re.M
        )
        self.assertIsNotNone(command)
        self.assertEqual(
            shlex.split(command.group(1)),
            [
                "${MONERO_HASH}",
                "300",
                "monero.tar.bz2",
                "https://downloads.getmonero.org/cli/monero-linux-x64-${MONERO_VERSION}.tar.bz2",
                "https://dlsrc.getmonero.org/cli/monero-linux-x64-${MONERO_VERSION}.tar.bz2",
            ],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
