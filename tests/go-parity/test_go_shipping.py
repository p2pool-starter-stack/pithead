import asyncio
import json
import os
import shutil
import socket
import subprocess
import sys
from pathlib import Path

import pytest
from aiohttp import ClientSession, ClientTimeout
from dashboard_storage_startup import CORE_TABLES, _main_source, _seed, _web_root

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]


def _environment():
    return {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}


def _entrypoint(tmp_path):
    source = (ROOT / "dashboard/entrypoint.sh").read_text()
    assert source.count("cd /app") == 1
    entrypoint = tmp_path / "entrypoint.sh"
    entrypoint.write_text(source.replace("cd /app", 'cd "$PITHEAD_TEST_APP"'))
    return entrypoint


def _probe(path):
    path.write_text(
        f"#!{sys.executable}\n"
        "import json, os, sys\n"
        "print(json.dumps({'argv':sys.argv[1:], 'pid':os.getpid(), "
        "'host':os.environ['HOST_IP'], 'mode':os.path.basename(sys.argv[0])}))\n"
        "sys.exit(23)\n"
    )
    path.chmod(0o755)


@pytest.mark.parametrize("implementation", [None, "", "bash", "python", "go"])
def test_container_entrypoint_selection_preserves_exec(tmp_path, implementation):
    entrypoint = _entrypoint(tmp_path)
    binaries = tmp_path / "bin"
    binaries.mkdir()
    for name in ("python3", "dashboard"):
        _probe(binaries / name)
    env = _environment()
    env.update(
        PATH=f"{binaries}:{env['PATH']}",
        PITHEAD_TEST_APP=str(tmp_path),
        PITHEAD_DASHBOARD_GO_BINARY=str(binaries / "dashboard"),
        HOST_IP="example.com",
    )
    if implementation is not None:
        env["PITHEAD_IMPL"] = implementation
    process = subprocess.Popen(
        ["bash", str(entrypoint)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    stdout, stderr = process.communicate(timeout=10)
    assert process.returncode == 23, stderr
    observed = json.loads(stdout)
    assert observed["pid"] == process.pid
    assert observed["host"] == "example.com"
    assert observed["mode"] == ("dashboard" if implementation == "go" else "python3")
    assert observed["argv"] == (
        [] if implementation == "go" else ["-u", "-m", "mining_dashboard.main"]
    )


@pytest.mark.parametrize("implementation", ["unsupported", "go"])
def test_container_entrypoint_never_silently_falls_back(tmp_path, implementation):
    binaries = tmp_path / "bin"
    binaries.mkdir()
    _probe(binaries / "python3")
    env = _environment()
    env.update(
        PATH=f"{binaries}:{env['PATH']}",
        PITHEAD_IMPL=implementation,
        PITHEAD_TEST_APP=str(tmp_path),
        PITHEAD_DASHBOARD_GO_BINARY=str(binaries / "missing"),
    )
    result = subprocess.run(
        ["bash", str(_entrypoint(tmp_path))], env=env, capture_output=True, timeout=10, check=False
    )
    assert result.returncode != 0
    assert result.stdout == b""
    assert result.stderr


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", ["existing", "legacy", "corrupt"])
async def test_container_selection_serves_native_storage_without_request_retries(tmp_path, kind):
    root = _web_root(tmp_path)
    (tmp_path / "mining_dashboard/main.py").write_text(_main_source())
    database, metadata = tmp_path / "storage.db", tmp_path / "metadata.json"
    _seed(database, kind)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    port = listener.getsockname()[1]
    env = _environment()
    env.update(
        PITHEAD_IMPL="go",
        PITHEAD_TEST_APP=str(tmp_path),
        PITHEAD_DASHBOARD_GO_BINARY=str(ROOT / "go/bin/dashboard"),
        PITHEAD_DASHBOARD_PYTHON=str(ROOT / "dashboard/.venv/bin/python"),
        PITHEAD_DASHBOARD_WEB_ROOT=str(root),
        PITHEAD_DASHBOARD_LISTEN_FD=str(listener.fileno()),
        PITHEAD_STORAGE_DB=str(database),
        PITHEAD_STORAGE_METADATA=str(metadata),
        PYTHONPATH=f"{tmp_path}:{ROOT / 'dashboard'}",
    )
    try:
        process = await asyncio.create_subprocess_exec(
            "bash",
            str(_entrypoint(tmp_path)),
            env=env,
            pass_fds=(listener.fileno(),),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
    finally:
        listener.close()
    try:
        async with ClientSession(timeout=ClientTimeout(total=15)) as session:
            async with session.get(f"http://127.0.0.1:{port}/api/state") as response:
                assert response.status == 200
                assert (await response.json())["db_healthy"] is True
            async with session.get(f"http://127.0.0.1:{port}/api/miner-connection") as response:
                assert response.status == 200
                assert response.headers["Cache-Control"] == "no-store"
        state = json.loads(metadata.read_text())
        assert state["class"] == "GoStateManager"
        assert CORE_TABLES <= set(state["tables"])
        assert state["reset_count"] == (1 if kind == "corrupt" else 0)
        if kind == "legacy":
            assert state["legacy_kv"] == "preserved"
        if kind == "corrupt":
            assert state["quarantine"] is True
    finally:
        if process.returncode is None:
            process.terminate()
        try:
            _, stderr = await asyncio.wait_for(process.communicate(), timeout=10)
        except TimeoutError:
            process.kill()
            await process.communicate()
            raise
        assert process.returncode == 0, stderr.decode(errors="replace")


@pytest.fixture(scope="session")
def linux_artifacts(tmp_path_factory):
    output = tmp_path_factory.mktemp("native-artifacts")
    env = os.environ.copy()
    env.update(CGO_ENABLED="0", GOOS="linux", GOARCH="amd64", GOPROXY="off")
    result = subprocess.run(
        ["go", "build", "-trimpath", "-o", f"{output}/", "./cmd/pithead", "./cmd/dashboard"],
        cwd=ROOT / "go",
        env=env,
        capture_output=True,
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return output


def _bundle(tmp_path, native=None, required=True):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL="go",
        PITHEAD_TEST_ROOT=str(ROOT),
        PITHEAD_TEST_WORK=str(tmp_path),
        PITHEAD_TEST_NATIVE=str(native) if native is not None else "",
        PITHEAD_REQUIRE_NATIVE_BUNDLE="1" if required else "0",
    )
    script = r"""
cd "$PITHEAD_TEST_ROOT" || exit 1
set --
source scripts/release/release.sh >/dev/null 2>&1
set +eu
REPO_ROOT=$PITHEAD_TEST_ROOT WORKDIR=$PITHEAD_TEST_WORK TAG=v9.9.9 DRY_RUN=0
GIT_COMMIT=0123456789abcdef0123456789abcdef01234567
for suffix in "${PUBLISHED_IMAGES[@]}"; do
    set_digest "$suffix" "$(image_for "$suffix")@sha256:$(printf '%064d' 1)"
done
make_bundle "$WORKDIR/pithead.tar.gz" "$PITHEAD_TEST_NATIVE"
"""
    return subprocess.run(
        ["bash", "-c", script], env=env, capture_output=True, timeout=45, check=False
    )


def test_release_bundle_contains_both_native_commands(tmp_path, linux_artifacts):
    result = _bundle(tmp_path, linux_artifacts)
    assert result.returncode == 0, result.stderr
    for name in ("pithead", "dashboard"):
        original = (linux_artifacts / name).read_bytes()
        shipped = tmp_path / "pithead/go/bin" / name
        assert shipped.read_bytes() == original
        assert original[:4] == b"\x7fELF"
        assert original[18:20] == b"\x3e\x00"
        assert os.access(shipped, os.X_OK)
    assert (tmp_path / "pithead/pithead").read_bytes() == (ROOT / "pithead").read_bytes()


@pytest.mark.parametrize("missing", [None, "pithead", "dashboard"])
def test_required_native_bundle_refuses_missing_commands(tmp_path, linux_artifacts, missing):
    artifacts = None
    if missing is not None:
        artifacts = tmp_path / "artifacts"
        artifacts.mkdir()
        for binary in linux_artifacts.iterdir():
            if binary.name != missing:
                shutil.copy2(binary, artifacts / binary.name)
    result = _bundle(tmp_path, artifacts)
    assert result.returncode != 0
    assert not (tmp_path / "pithead.tar.gz").exists()


def test_reference_bundle_api_stays_available_without_native_commands(tmp_path):
    result = _bundle(tmp_path, required=False)
    assert result.returncode == 0, result.stderr
    assert not (tmp_path / "pithead/go/bin/pithead").exists()
    assert (tmp_path / "pithead.tar.gz").is_file()


def test_installed_native_cli_layout_retains_reference_fallback(tmp_path):
    (tmp_path / "go/bin").mkdir(parents=True)
    for source, target in (
        (ROOT / "pithead", tmp_path / "pithead"),
        (ROOT / "VERSION", tmp_path / "VERSION"),
        (ROOT / "go/bin/pithead", tmp_path / "go/bin/pithead"),
    ):
        shutil.copy2(source, target)
    for arguments in (("--help",), ("--version",), ("setup", "--help")):
        results = []
        for implementation in ("bash", "go"):
            env = _environment()
            env["PITHEAD_IMPL"] = implementation
            result = subprocess.run(
                [str(tmp_path / "pithead"), *arguments],
                cwd=tmp_path,
                env=env,
                capture_output=True,
                timeout=20,
                check=False,
            )
            results.append((result.returncode, result.stdout, result.stderr))
        assert results[0] == results[1]
