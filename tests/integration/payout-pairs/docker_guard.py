"""Run fixture apply behind a Docker API boundary that denies other projects' containers."""

import http.client
import http.server
import json
import os
import re
import socket
import socketserver
import subprocess
import sys
import threading
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit


class DockerConnection(http.client.HTTPConnection):
    def __init__(self):
        super().__init__("localhost", timeout=30)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect("/var/run/docker.sock")


class Policy:
    default_why = "not a fixture-owned name, label or resource"

    def __init__(self, project, inspect, work):
        self.project, self.inspect, self.work = project, inspect, Path(work).resolve()
        self.why = self.default_why

    def fixture_name(self, name):
        return name.startswith(self.project + "_") or name.startswith(self.project + "-")

    def container_name(self, name):
        if self.fixture_name(name):
            return True
        replaced = re.fullmatch(r"([0-9a-f]{12})_(.+)", name)
        return bool(
            replaced and self.fixture_name(replaced[2]) and self.owned("containers", replaced[1])
        )

    def mount_allowed(self, kind, source):
        if kind == "volume":
            return self.fixture_name(source) and (
                not self.inspect("volumes", source) or self.owned("volumes", source)
            )
        if kind != "bind":
            return kind == "tmpfs"
        source = Path(source).resolve()
        return source.is_relative_to(self.work) and not source.is_socket()

    def deny(self, why):
        self.why = why
        return False

    def container_allowed(self, body):
        host = body.get("HostConfig", {})
        if "ALL" not in (host.get("CapDrop") or []) or any(
            host.get(k)
            for k in ("Privileged", "Devices", "DeviceRequests", "DeviceCgroupRules", "VolumesFrom")
        ):
            return self.deny("capabilities not dropped or privileged/device/volumes-from")
        if host.get("VolumeDriver") not in (None, "", "local"):
            return self.deny("volume driver")
        if {c.removeprefix("CAP_") for c in host.get("CapAdd") or []} - {
            "CHOWN",
            "DAC_OVERRIDE",
            "SETUID",
            "SETGID",
        }:
            return self.deny("capability added")
        if any(
            host.get(k) not in (None, "", "private") for k in ("PidMode", "IpcMode", "UsernsMode")
        ):
            return self.deny("pid/ipc/userns mode")
        if host.get("NetworkMode") in ("host",) or (host.get("NetworkMode") or "").startswith(
            "container:"
        ):
            return self.deny("network mode")
        for mount in host.get("Mounts") or []:
            if (mount.get("VolumeOptions") or {}).get("DriverConfig"):
                return self.deny("mount driver")
            if not self.mount_allowed(mount.get("Type"), mount.get("Source", "")):
                return self.deny(f"mount source {mount.get('Source')}")
        for bind in host.get("Binds") or []:
            source = bind.split(":", 1)[0]
            if not self.mount_allowed("bind" if source.startswith("/") else "volume", source):
                return self.deny(f"bind source {source}")
        return True

    def owned(self, kind, name):
        item = self.inspect(kind, name)
        labels = (
            item.get("Config", {}).get("Labels", {})
            if kind == "containers"
            else item.get("Labels", {})
        )
        return (labels or {}).get("com.docker.compose.project") == self.project

    def allows(self, method, path, body):
        self.why = self.default_why
        query = parse_qs(urlsplit(path).query)
        path = re.sub(r"^/v[0-9.]+", "", unquote(urlsplit(path).path))
        bits = path.strip("/").split("/")
        if bits[0] in ("containers", "volumes", "networks"):
            kind = bits[0]
            if len(bits) == 1 or bits[1] == "json":
                return method == "GET"
            if bits[1] == "create":
                if (
                    method != "POST"
                    or (body.get("Labels") or {}).get("com.docker.compose.project") != self.project
                ):
                    return False
                if kind == "containers":
                    return self.container_name(
                        query.get("name", [""])[0]
                    ) and self.container_allowed(body)
                name = body.get("Name", "")
                return (
                    self.fixture_name(name)
                    and (not self.inspect(kind, name) or self.owned(kind, name))
                    and not body.get("DriverOpts")
                    and body.get("Driver") in (None, "", "local")
                )
            if bits[1] == "prune":
                return False
            if kind == "networks" and method == "GET":
                return True  # Compose needs to inspect the external shared network.
            if kind == "networks" and bits[-1] in ("connect", "disconnect"):
                return self.owned("containers", body.get("Container", ""))
            if (
                kind == "containers"
                and bits[-1] == "rename"
                and not self.fixture_name(query.get("name", [""])[0])
            ):
                return False
            if method in ("GET", "HEAD") and not self.inspect(kind, bits[1]):
                return True  # Relay the daemon's 404; Compose then creates its fixture resource.
            return self.owned(kind, bits[1])
        # Images are prebuilt/pulled before apply. No unscoped Docker mutation is forwarded.
        return method in ("GET", "HEAD") and bits[0] in (
            "_ping",
            "version",
            "info",
            "images",
            "events",
        )


def inspect(kind, name):
    connection = DockerConnection()
    try:
        connection.request(
            "GET", f"/{kind}/{name}/json" if kind == "containers" else f"/{kind}/{name}"
        )
        response = connection.getresponse()
        return json.loads(response.read()) if response.status == 200 else {}
    finally:
        connection.close()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass  # Requests can contain keys; never log them.

    def relay(self):
        connection = DockerConnection()
        try:
            raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            body = json.loads(raw) if raw else {}
            if not self.server.policy.allows(self.command, self.path, body):
                # Method, path and rule only: bodies can carry keys.
                print(
                    f"guard denied {self.command} {self.path}: {self.server.policy.why}",
                    file=sys.stderr,
                    flush=True,
                )
                self.send_error(403, "outside fixture project")
                return
            headers = {k: v for k, v in self.headers.items() if k.lower() != "connection"}
            connection.request(self.command, self.path, raw, headers)
            response = connection.getresponse()
            clean = re.sub(r"^/v[0-9.]+", "", urlsplit(self.path).path)
            if clean in ("/containers/json", "/volumes", "/networks") and response.status == 200:
                data = json.loads(response.read())
                items = data.get("Volumes", []) if clean == "/volumes" else data
                items = [
                    i
                    for i in (items or [])
                    if (i.get("Labels") or {}).get("com.docker.compose.project")
                    == self.server.policy.project
                ]
                payload = json.dumps(
                    {**data, "Volumes": items} if clean == "/volumes" else items
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() not in ("transfer-encoding", "connection"):
                    self.send_header(key, value)
            self.end_headers()
            while chunk := response.read1(65536):
                self.wfile.write(chunk)
                self.wfile.flush()
        except (OSError, ValueError, http.client.HTTPException):
            self.close_connection = True
        finally:
            connection.close()

    do_GET = do_HEAD = do_POST = do_DELETE = do_PUT = relay


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    address_family = socket.AF_UNIX
    daemon_threads = False

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "localhost", 0


def main():
    project, path, *command = sys.argv[1:]
    with Server(path, Handler) as server:
        os.chmod(path, 0o600)
        server.policy = Policy(project, inspect, Path(path).parent)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            return subprocess.run(command, check=False).returncode  # noqa: S603
        finally:
            server.shutdown()
            thread.join()
            os.unlink(path)


if __name__ == "__main__":
    sys.exit(main())
