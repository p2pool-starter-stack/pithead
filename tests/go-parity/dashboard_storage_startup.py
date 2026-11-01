# ruff: noqa: S101, S608
import json
import sqlite3
import time
from pathlib import Path

import pytest
from aiohttp import ClientSession
from dashboard_http_plugin import DashboardProcess

REPO_ROOT = Path(__file__).resolve().parents[2]
REAL_PACKAGE = REPO_ROOT / "dashboard" / "mining_dashboard"
PYTHON = REPO_ROOT / "dashboard" / ".venv" / "bin" / "python"
CORE_TABLES = {
    "history",
    "kv_store",
    "shares",
    "events",
    "share_stats",
    "payouts",
    "worker_config",
    "blocks",
    "raffle_wins",
    "xvb_history",
    "network_history",
    "disk_growth",
    "worker_history",
    "audit_events",
    "worker_config_revision",
}

pytestmark = pytest.mark.asyncio


def _web_root(tmp_path, block_go_storage=False):
    package = tmp_path / "mining_dashboard"
    templates = package / "web" / "templates"
    templates.mkdir(parents=True)
    (templates / "index.html").write_text("<h1>storage startup fixture</h1>\n")
    package_init = (
        "from pathlib import Path\n"
        f"__path__ = [str(Path(__file__).parent), {str(REAL_PACKAGE)!r}]\n"
    )
    if block_go_storage:
        package_init += """
import sys
class BlockGoStorage:
    def find_spec(self, fullname, path, target=None):
        if fullname == "mining_dashboard.go_storage":
            raise ModuleNotFoundError(name=fullname)
sys.meta_path.insert(0, BlockGoStorage())
"""
    (package / "__init__.py").write_text(package_init)
    return package / "web"


def _main_source():
    lifecycle = (
        "_init_db",
        "_apply_schema",
        "_check_integrity",
        "_is_corruption_error",
        "_prune_quarantined",
        "_create_tables",
        "_migrate_db",
        "_create_indexes",
    )
    return f"""
import json
import os
from pathlib import Path
from mining_dashboard import go_storage
from mining_dashboard.service import storage_schema, storage_service
from mining_dashboard.service.workers import worker_config_store
from mining_dashboard.web import server

SHUTDOWN_TIMEOUT = 0.1

def fatal(*args, **kwargs):
    raise AssertionError("Python storage lifecycle used")

def build_app():
    for name in {lifecycle!r}:
        setattr(storage_schema.StorageSchemaMixin, name, fatal)
    worker_config_store.WorkerConfigStoreMixin._migrate_worker_config_revision = fatal
    go_storage.StateManager._recover_corrupt_db = fatal
    go_storage.StateManager._db_error = fatal
    storage_service.sqlite3.connect = fatal
    manager = storage_service.StateManager(db_path=os.environ["PITHEAD_STORAGE_DB"])
    tables = sorted(
        row[0]
        for row in manager._conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        ).fetchall()
    )
    reset = manager.last_db_reset
    quarantine = reset.get("quarantine") if reset else None
    metadata = {{
        "class": type(manager).__name__,
        "module": type(manager).__module__,
        "healthy": manager.is_db_healthy(),
        "unrecoverable": manager.is_db_unrecoverable(),
        "reset_count": manager.db_reset_count,
        "reset_reason": reset.get("reason") if reset else None,
        "quarantine": bool(quarantine and Path(quarantine).is_file()),
        "tables": tables,
        "history": manager.get_history(),
        "legacy_kv": manager.get_kv("legacy-key"),
    }}
    Path(os.environ["PITHEAD_STORAGE_METADATA"]).write_text(json.dumps(metadata))
    app = server.create_app(manager, {{}})
    async def close(_app):
        manager.close()
    app.on_cleanup.append(close)
    return app
"""


def _seed(path, kind):
    if kind == "corrupt":
        path.write_bytes(b"not a sqlite database" * 32)
        return
    connection = sqlite3.connect(path)
    if kind == "legacy":
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(time.time() - 60))
        connection.execute("CREATE TABLE history (t TEXT, v REAL)")
        connection.execute("INSERT INTO history VALUES (?, ?)", (stamp, 3811.0))
        connection.execute("CREATE TABLE kv_store (key TEXT PRIMARY KEY, value TEXT)")
        connection.execute("INSERT INTO kv_store VALUES ('legacy-key', 'preserved')")
        connection.execute("CREATE TABLE workers (name TEXT)")
    connection.commit()
    connection.close()


async def _start(tmp_path, monkeypatch, kind):
    web_root = _web_root(tmp_path)
    (tmp_path / "mining_dashboard" / "main.py").write_text(_main_source())
    database = tmp_path / "storage.db"
    metadata = tmp_path / "metadata.json"
    _seed(database, kind)
    monkeypatch.delenv("PITHEAD_DASHBOARD_REFERENCE_URL", raising=False)
    monkeypatch.setenv("PITHEAD_STORAGE_DB", str(database))
    monkeypatch.setenv("PITHEAD_STORAGE_METADATA", str(metadata))
    process = DashboardProcess(None, False, web_root=web_root, python=PYTHON)
    await process.start()
    return process, database, metadata


@pytest.mark.parametrize("kind", ["existing", "legacy", "corrupt"])
async def test_runtime_starts_with_native_storage(monkeypatch, tmp_path, kind):
    process, database, metadata_path = await _start(tmp_path, monkeypatch, kind)
    try:
        metadata = json.loads(metadata_path.read_text())
        assert metadata["class"] == "GoStateManager"
        assert metadata["module"] == "mining_dashboard.go_storage"
        assert metadata["healthy"] is True
        assert metadata["unrecoverable"] is False
        assert CORE_TABLES <= set(metadata["tables"])
        async with ClientSession() as session:
            async with session.get(f"{process.url}/api/state") as response:
                assert response.status == 200
                state = await response.json()
                assert state["db_healthy"] is True
            async with session.get(f"{process.url}/api/miner-connection") as response:
                assert response.status == 200
                miner = await response.json()
                assert {"url", "local_only", "password_set", "tls", "fingerprint"} <= set(miner)
                assert response.headers["Cache-Control"] == "no-store"
        if kind == "legacy":
            assert metadata["reset_count"] == 0
            assert metadata["legacy_kv"] == "preserved"
            assert metadata["history"][-1]["v"] == 3811.0
            assert "workers" not in metadata["tables"]
        elif kind == "corrupt":
            assert metadata["reset_count"] == 1
            assert metadata["quarantine"] is True
            assert metadata["reset_reason"] == "startup: file is not a database"
            assert metadata["history"] == []
            assert database.is_file()
        else:
            assert metadata["reset_count"] == 0
            assert metadata["history"] == []
    finally:
        await process.close()


async def test_runtime_fails_before_main_without_native_storage(monkeypatch, tmp_path):
    web_root = _web_root(tmp_path, block_go_storage=True)
    marker = tmp_path / "main-imported"
    database = tmp_path / "python-storage.db"
    (tmp_path / "mining_dashboard" / "main.py").write_text(
        "import os\n"
        "import sqlite3\n"
        "from pathlib import Path\n"
        "Path(os.environ['PITHEAD_STORAGE_MARKER']).write_text('imported')\n"
        "sqlite3.connect(os.environ['PITHEAD_STORAGE_DB']).close()\n"
        "SHUTDOWN_TIMEOUT = 0.1\n"
        "def build_app():\n"
        "    raise AssertionError('build_app ran')\n"
    )
    monkeypatch.delenv("PITHEAD_DASHBOARD_REFERENCE_URL", raising=False)
    monkeypatch.setenv("PITHEAD_STORAGE_MARKER", str(marker))
    monkeypatch.setenv("PITHEAD_STORAGE_DB", str(database))
    process = DashboardProcess(None, False, web_root=web_root, python=PYTHON)
    try:
        with pytest.raises(RuntimeError, match="exited during startup"):
            await process.start()
    finally:
        await process.close()
    assert not marker.exists()
    assert not database.exists()
