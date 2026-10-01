"""CI contract: real libcurl retries a connection-bound Digest challenge on one socket."""

import hmac
import importlib.util
import json
import os
import shutil
import subprocess
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest.mock import patch
from urllib.request import parse_http_list, parse_keqv_list

SOURCE = Path(__file__).resolve().parents[1] / "lib" / "restore-chain-sync.py"
spec = importlib.util.spec_from_file_location("restore_curl_connection", SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CurlConnection(unittest.TestCase):
    def exchange(self, close=False, unauthenticated=False, redirect=False, password="changeme"):  # noqa: S107 -- synthetic fixture
        openssl = shutil.which("openssl")
        self.assertIsNotNone(openssl, "required OpenSSL fixture verifier unavailable")
        requests = []
        connections = []

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def setup(self):
                super().setup()
                self.connection.settimeout(3)
                connections.append(self)
                self.seen = 0

            def log_message(self, *args):
                pass  # Never print credentials, request headers or endpoint details.

            def do_GET(self):
                self.seen += 1
                auth = self.headers.get("Authorization", "")
                requests.append((self, auth))
                # The nonce belongs to this accepted connection, like Monero's.
                accepted = False
                if self.seen == 2 and auth.startswith("Digest "):
                    fields = parse_keqv_list(parse_http_list(auth[7:]))
                    # Fixed synthetic HA1/HA2; OpenSSL independently verifies the
                    # wire response. No custom hash implementation or real login.
                    expected = (
                        subprocess.run(  # noqa: S603 -- fixed OpenSSL fixture verifier; synthetic fields on stdin
                            [openssl, "dgst", "-md5"],
                            input=(
                                "9df957996c80eb5e9553265fce63d6c6:connection-nonce:"
                                + fields.get("nc", "")
                                + ":"
                                + fields.get("cnonce", "")
                                + ":auth:c93d919f0a447e262d077d2f6fb0b553"
                            ),
                            capture_output=True,
                            text=True,
                            timeout=2,
                            check=True,
                        )
                        .stdout.strip()
                        .split()[-1]
                    )
                    accepted = (
                        fields.get("username") == "fixture-user"
                        and fields.get("nonce") == "connection-nonce"
                        and fields.get("uri") == "/get_info"
                        and fields.get("qop") == "auth"
                        and fields.get("nc") == "00000001"
                        and hmac.compare_digest(fields.get("response", ""), expected)
                    )
                payload = json.dumps({"status": "OK", "synchronized": True}).encode()
                self.send_response(302 if redirect else 200 if accepted or unauthenticated else 401)
                if redirect:
                    self.send_header("Location", "http://redirect.invalid/get_info")
                if not accepted and not unauthenticated:
                    self.send_header(
                        "WWW-Authenticate",
                        'Digest realm="fixture", nonce="connection-nonce", algorithm=MD5, qop="auth"',
                    )
                self.send_header("Content-Length", str(len(payload)))
                if close or self.seen > 1:
                    self.send_header("Connection", "close")
                    self.close_connection = True
                self.end_headers()
                self.wfile.write(payload)

        with HTTPServer(("localhost", 0), Handler) as server:
            server.timeout = 3

            def serve():
                # Two accepts are enough for the forced-close refusal. No daemon thread.
                server.handle_request()
                if close:
                    server.handle_request()

            worker = threading.Thread(target=serve)
            worker.start()
            try:
                with patch.dict(
                    os.environ,
                    {"http_proxy": "http://proxy.invalid", "ALL_PROXY": "http://proxy.invalid"},
                ):
                    result = module.monero_info(
                        "http://localhost:" + str(server.server_port), "fixture-user", password
                    )
                self.assertEqual(len(connections), 1)
                self.assertEqual(len(requests), 2)
                self.assertIs(requests[0][0], requests[1][0])
                self.assertFalse(requests[0][1])
                self.assertTrue(requests[1][1].startswith("Digest "))
                return result
            finally:
                worker.join(timeout=7)
                self.assertFalse(worker.is_alive(), "bounded Digest fixture did not finish")

    def test_connection_bound_challenge_and_authorized_request_share_socket(self):
        self.assertIs(self.exchange()["synchronized"], True)

    def test_closed_session_redirect_unauthenticated_ok_and_bad_login_refuse(self):
        for options in (
            {"close": True},
            {"unauthenticated": True},
            {"redirect": True},
            {"password": "wrong-fixture-login"},
        ):
            with (
                self.subTest(options=options),
                self.assertRaises((ValueError, module.subprocess.CalledProcessError)),
            ):
                self.exchange(**options)


if __name__ == "__main__":
    unittest.main()
