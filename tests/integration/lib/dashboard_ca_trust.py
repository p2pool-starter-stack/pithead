import hashlib
import json
import os
import re
import selectors
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CA_PATH = "/data/caddy/pki/authorities/local/root.crt"
CA_FILE = "pithead-dashboard-ca.crt"
IMAGE = "pithead-dashboard-ca:test"
EXPORT = f"docker compose exec -T caddy cat {CA_PATH} > {CA_FILE}"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def documented_export(document):
    commands = re.findall(r"```bash\n(docker compose exec -T caddy cat [^\n]+)\n```", document)
    require(commands == [EXPORT], "documented export must copy only Caddy's public root.crt")
    return commands[0]


def run(args, **kwargs):
    kwargs.setdefault("timeout", 60)
    return subprocess.run(args, check=True, **kwargs)  # noqa: S603


def export_ca(directory):
    command = documented_export((ROOT / "docs/configuration.md").read_text())
    environment = dict(os.environ, COMPOSE_FILE=str(Path.cwd() / "docker-compose.yml"))
    run(["bash", "-e", "-c", command], cwd=directory, env=environment)
    certificate = Path(directory, CA_FILE).read_bytes()
    require(certificate.count(b"-----BEGIN CERTIFICATE-----") == 1, "export is not one certificate")
    require(b"PRIVATE KEY" not in certificate, "CA export contained private material")
    return hashlib.sha256(certificate).digest()


def rotate_leaf():
    try:
        run(["docker", "compose", "stop", "caddy"], stdout=subprocess.DEVNULL)
        run(
            [
                "docker",
                "compose",
                "run",
                "--rm",
                "--no-deps",
                "--entrypoint",
                "sh",
                "caddy",
                "-c",
                "rm -f /data/caddy/certificates/local/*/*.crt "
                "/data/caddy/certificates/local/*/*.key /data/caddy/certificates/local/*/*.json",
            ],
            stdout=subprocess.DEVNULL,
        )
    finally:
        run(["docker", "compose", "up", "-d", "--no-deps", "caddy"], stdout=subprocess.DEVNULL)


def wait_https(origin):
    curl = shutil.which("curl")
    require(curl, "curl is required for Caddy readiness polling")
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        response = subprocess.run(  # noqa: S603
            [
                curl,
                "-ksS",
                "--noproxy",
                "*",
                "--max-time",
                "3",
                "-o",
                os.devnull,
                "--write-out",
                "%{http_code}",
                origin,
            ],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if response.returncode == 0 and response.stdout in {"200", "401"}:
            return
        time.sleep(2)
    raise RuntimeError("Caddy did not serve HTTPS within 60s")


def prove():
    env = {}
    for line in Path(".env").read_text().splitlines():
        key, separator, value = line.partition("=")
        if separator and key in {"DASHBOARD_SECURE", "HOST_IP", "HOST_PORT"}:
            env[key] = value.strip("'\"")
    require(env.get("DASHBOARD_SECURE") == "true", "CA proof requires the DIY HTTPS dashboard")
    require(
        "tls internal" in Path("Caddyfile").read_text(), "CA proof requires Caddy's internal CA"
    )
    host = env["HOST_IP"]
    if ":" in host:
        host = f"[{host}]"
    origin = f"https://{host}:{env.get('HOST_PORT') or '443'}"
    auth = json.loads(Path("config.json").read_text())["dashboard"]["auth"]
    run(
        ["docker", "build", "-q", "-t", IMAGE, str(ROOT / "dashboard/tests/browser")],
        timeout=900,
    )
    with tempfile.TemporaryDirectory(prefix="pithead-ca-") as directory:
        identity = export_ca(directory)
        name = f"pithead-ca-{os.getpid()}"
        command = [
            "docker",
            "run",
            "--rm",
            "-i",
            "--name",
            name,
            "--network",
            "host",
            "--read-only",
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges",
            "--tmpfs",
            "/tmp:rw,exec,size=512m",  # noqa: S108 - private container tmpfs, not the host filesystem.
            "--shm-size",
            "256m",
            "--mount",
            f"type=bind,src={directory}/{CA_FILE},dst=/root.crt,readonly",
            IMAGE,
        ]
        with Path(directory, "browser.stderr").open("w+") as errors:
            process = subprocess.Popen(  # noqa: S603
                command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True
            )
            selector = selectors.DefaultSelector()
            try:
                selector.register(process.stdout, selectors.EVENT_READ)
                process.stdin.write(json.dumps({"origin": origin, "auth": auth}) + "\n")
                process.stdin.flush()
                expected = iter(
                    [
                        "leaf-accepted",
                        "rotate-leaf-only",
                        "leaf-only-red",
                        "root-trusted",
                        "rotate-root-trusted",
                        "root-trust-green",
                    ]
                )
                for event in expected:
                    require(selector.select(120), "browser protocol timed out")
                    line = process.stdout.readline()
                    require(bool(line), f"browser stopped before {event}")
                    require(json.loads(line) == {"event": event}, "unexpected browser event")
                    if event.startswith("rotate-"):
                        rotate_leaf()
                        wait_https(origin)
                        require(
                            export_ca(directory) == identity,
                            "Caddy root CA changed during rotation",
                        )
                    elif event == "leaf-only-red":
                        print(
                            "dashboard-ca: leaf-only acceptance re-warns after rotation (RED control)",
                            flush=True,
                        )
                    elif event == "root-trust-green":
                        print("dashboard-ca: root trust survives leaf rotation (GREEN)", flush=True)
                    process.stdin.write('{"continue": true}\n')
                    process.stdin.flush()
                require(process.wait(timeout=30) == 0, "browser failed after final assertion")
            finally:
                selector.close()
                if process.poll() is None:
                    run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL)
                    process.wait(timeout=30)
                process.stdin.close()
                process.stdout.close()
                errors.seek(0)
                print(errors.read()[-2000:], end="", flush=True)
    print("dashboard-ca: complete", flush=True)


if __name__ == "__main__":

    def interrupted(_signum, _frame):
        raise SystemExit("dashboard-ca: interrupted")

    signal.signal(signal.SIGTERM, interrupted)
    prove()
