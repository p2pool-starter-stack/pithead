"""Exercise the four CI uv installers against a transient download failure."""

import http.server
import subprocess
import tempfile
import threading
from pathlib import Path

workflow = Path(".github/workflows/ci.yml").read_text()
commands = [
    line.strip().split(" #", 1)[0]
    for line in workflow.splitlines()
    if "curl " in line and "uv/0.12.13/install.sh" in line
]
if len(commands) != 4 or len(set(commands)) != 1:
    raise SystemExit("expected four identical pinned uv installer commands")


class Installer(http.server.BaseHTTPRequestHandler):
    requests = 0

    def do_GET(self):
        type(self).requests += 1
        if self.requests == 1:
            self.close_connection = True
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"exit 0\n")

    def log_message(self, *_args):
        pass


with (
    http.server.HTTPServer(("localhost", 0), Installer) as server,
    tempfile.TemporaryDirectory() as directory,
):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    command = commands[0].replace(
        "https://astral.sh/uv/0.12.13/install.sh",
        f"http://localhost:{server.server_port}/install.sh",
    )
    command = command.replace("/tmp/uv-install.sh", f"{directory}/uv-install.sh")  # noqa: S108
    result = subprocess.run(  # noqa: S603
        ["bash", "-e", "-c", command],  # noqa: S607
        capture_output=True,
        text=True,
        timeout=20,
    )
    server.shutdown()
    thread.join()

if result.returncode != 0 or Installer.requests != 2:
    raise SystemExit(
        f"uv installer retry failed: exit={result.returncode}, requests={Installer.requests}, stderr={result.stderr}"
    )
