import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

# ruff: noqa: S106, S603, S607, S108

START = r"""
import os, sqlite3
from pathlib import Path
database = Path('/data/mining_data.db')
kind = os.environ['PITHEAD_IMAGE_TEST_KIND']
if kind == 'corrupt':
    database.write_bytes(b'not a sqlite database' * 32)
elif kind == 'legacy':
    connection = sqlite3.connect(database)
    connection.execute('CREATE TABLE history (t TEXT, v REAL)')
    connection.execute('CREATE TABLE kv_store (key TEXT PRIMARY KEY, value TEXT)')
    connection.execute("INSERT INTO kv_store VALUES ('shipping', 'preserved')")
    connection.commit()
    connection.close()
if os.environ['PITHEAD_IMPL'] == 'go':
    Path('/tmp/sitecustomize.py').write_text(
        "import sqlite3\n"
        "def forbidden(*args, **kwargs):\n"
        "    raise AssertionError('Python SQLite opened in Go image')\n"
        "sqlite3.connect = forbidden\n")
    os.environ['PYTHONPATH'] = '/tmp'
os.execv('/app/entrypoint.sh', ['/app/entrypoint.sh'])
"""

CHECK = r"""
import json, os, sqlite3, urllib.request
from pathlib import Path
url = 'http://127.0.0.1:8000'
with urllib.request.urlopen(url + '/api/state', timeout=5) as response:
    state = json.load(response)
    assert state['db_healthy'] is True
with urllib.request.urlopen(url + '/api/miner-connection', timeout=5) as response:
    miner = json.load(response)
    assert {'url','local_only','password_set','tls','fingerprint'} <= set(miner)
    assert response.headers['Cache-Control'] == 'no-store'
binary = os.readlink('/proc/1/exe')
if os.environ['PITHEAD_IMPL'] == 'go':
    assert binary == '/app/go/bin/dashboard', binary
    assert Path('/tmp/sitecustomize.py').is_file()
else:
    assert 'python' in binary, binary
connection = sqlite3.connect('/data/mining_data.db')
tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
assert {'history','kv_store','shares','worker_config','worker_config_revision'} <= tables
if os.environ['PITHEAD_IMAGE_TEST_KIND'] == 'legacy':
    assert connection.execute("SELECT value FROM kv_store WHERE key='shipping'").fetchone()[0] == 'preserved'
connection.close()
if os.environ['PITHEAD_IMAGE_TEST_KIND'] == 'corrupt':
    assert len(list(Path('/data').glob('mining_data.db.corrupt-*'))) == 1
print(json.dumps({'implementation':os.environ['PITHEAD_IMPL'],
                  'database':os.environ['PITHEAD_IMAGE_TEST_KIND'], 'tables':len(tables)}))
"""


def docker(*arguments, timeout=30):
    return subprocess.run(
        ["docker", *arguments], capture_output=True, text=True, timeout=timeout, check=False
    )


def check_image(image, implementation, kind):
    created = docker(
        "run",
        "--detach",
        "--pull=never",
        "--network",
        "none",
        "--read-only",
        "--tmpfs",
        "/tmp:mode=1777",
        "--tmpfs",
        "/data:uid=1000,gid=1000,mode=0700",
        "--tmpfs",
        "/clearnet-state:uid=1000,gid=1000,mode=0700",
        "--env",
        f"PITHEAD_IMPL={implementation}",
        "--env",
        f"PITHEAD_IMAGE_TEST_KIND={kind}",
        "--entrypoint",
        "python3",
        image,
        "-c",
        START,
    )
    if created.returncode:
        raise RuntimeError(created.stderr)
    container = created.stdout.strip()
    try:
        deadline = time.monotonic() + 45
        while True:
            health = docker("exec", container, "/app/healthcheck.sh", timeout=10)
            if health.returncode == 0:
                break
            running = docker("inspect", "--format", "{{.State.Running}}", container)
            if running.stdout.strip() != "true" or time.monotonic() >= deadline:
                raise RuntimeError("dashboard image did not become healthy")
            time.sleep(0.25)
        checked = docker("exec", container, "python3", "-I", "-c", CHECK)
        if checked.returncode:
            raise RuntimeError(checked.stderr)
        print(checked.stdout.strip(), flush=True)
        stopped = docker("stop", "--time", "10", container, timeout=20)
        state = docker("inspect", "--format", "{{json .State}}", container)
        status = json.loads(state.stdout)
        if stopped.returncode or status["ExitCode"] != 0 or status["OOMKilled"]:
            raise RuntimeError("dashboard image did not stop cleanly")
    finally:
        docker("rm", "--force", container)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_go_image.py IMAGE")
    for implementation, kind in (
        ("python", "existing"),
        ("go", "existing"),
        ("go", "legacy"),
        ("go", "corrupt"),
    ):
        check_image(sys.argv[1], implementation, kind)
    for cli, backend, expected in (
        ("go", "", "python"),
        ("bash", "go", "go"),
        ("go", "python", "python"),
    ):
        env = os.environ.copy()
        compose = (Path(__file__).resolve().parents[2] / "docker-compose.yml").read_text()
        for name in re.findall(r"\$\{([A-Z][A-Z0-9_]+)", compose):
            env.pop(name, None)
        for name in re.findall(r"\$\{([A-Z][A-Z0-9_]+)\}", compose):
            env[name] = (
                f"/tmp/pithead-shipping-fixture/{name}"
                if name.endswith("_DIR")
                else "1"
                if "PORT" in name or "THREADS" in name
                else "fixture"
            )
        env.update(
            PITHEAD_IMPL=cli,
            PITHEAD_DASHBOARD_IMPL=backend,
            PROXY_API_PORT="1",
            PROXY_AUTH_TOKEN="fixture",
        )
        configured = subprocess.run(
            ["docker", "compose", "--env-file", os.devnull, "config", "--format", "json"],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
        if configured.returncode:
            raise RuntimeError("Compose selection configuration failed")
        dashboard = json.loads(configured.stdout)["services"]["dashboard"]
        if dashboard["environment"]["PITHEAD_IMPL"] != expected:
            raise RuntimeError("CLI selection leaked into dashboard selection")
        if dashboard["build"]["target"] != "go-production":
            raise RuntimeError("Compose did not select the Go-capable image target")
    print("Compose selection: three cases passed", flush=True)


if __name__ == "__main__":
    main()
