import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "healthcheck.sh"


def _server(status):
    seen = []

    class Handler(BaseHTTPRequestHandler):
        def do_HEAD(self):
            seen.append(self.path)
            self.send_response(status)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, seen


def _run(port):
    env = {"PATH": "/usr/bin:/bin", "DASHBOARD_HEALTH_PORT": str(port)}
    command = ["/bin/bash", str(SCRIPT)]
    return subprocess.run(command, env=env, timeout=30, check=False).returncode  # noqa: S603


@pytest.mark.parametrize(
    ("status", "healthy"), [(200, True), (204, True), (401, False), (500, False)]
)
def test_healthcheck_follows_the_state_route_status(status, healthy):
    server, seen = _server(status)
    try:
        assert (_run(server.server_address[1]) == 0) is healthy
        assert seen == ["/api/state"]
    finally:
        server.shutdown()
        server.server_close()


def test_healthcheck_fails_on_a_closed_port():
    server, _ = _server(200)
    port = server.server_address[1]
    server.shutdown()
    server.server_close()
    assert _run(port) != 0


def test_healthcheck_starts_no_python():
    assert "python" not in SCRIPT.read_text()
