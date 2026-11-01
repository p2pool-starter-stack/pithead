import json

import pytest
from aiohttp import ClientSession
from dashboard_http_plugin import DashboardProcess
from dashboard_storage_startup import PYTHON, _web_root

# ruff: noqa: S101

RID = "12345678-1234-5678-90ab-1234567890ab"


def _main_source():
    return """
from mining_dashboard.service import control_service, request_spool, storage_service
from mining_dashboard.web import server
SHUTDOWN_TIMEOUT = 0.1
originals = [request_spool.write] + [getattr(control_service, name) for name in (
    "submit", "submit_worker_apply", "submit_worker_upgrade", "validate_worker_changes", "result")]
def fatal(*args, **kwargs):
    raise AssertionError("Python control protocol used")
def build_app():
    assert request_spool.write.__module__ == "mining_dashboard.go_control"
    assert control_service.submit.__module__ == "mining_dashboard.go_control"
    for original in originals:
        original.__code__ = fatal.__code__
    manager = storage_service.StateManager(":memory:")
    app = server.create_app(manager, {})
    async def close(_app):
        manager.close()
    app.on_cleanup.append(close)
    return app
"""


async def test_normal_dashboard_command_uses_native_control(tmp_path, monkeypatch):
    root = _web_root(tmp_path)
    (tmp_path / "mining_dashboard/main.py").write_text(_main_source())
    requests = tmp_path / "requests"
    results = tmp_path / "results"
    requests.mkdir()
    results.mkdir()
    monkeypatch.setenv("CONTROL_REQUESTS_DIR", str(requests))
    monkeypatch.setenv("CONTROL_RESULTS_DIR", str(results))
    monkeypatch.delenv("PITHEAD_DASHBOARD_REFERENCE_URL", raising=False)
    process = DashboardProcess(None, True, web_root=root, python=PYTHON)
    await process.start()
    try:
        async with ClientSession() as session:
            async with session.post(
                f"{process.url}/api/control/upgrade",
                json={"version": "v9.9.9"},
                headers={"X-Pithead-Control": "1", "X-Auth-User": "operator"},
            ) as response:
                assert response.status == 202
                rid = (await response.json())["id"]
            assert json.loads((requests / f"{rid}.json").read_text()) == {
                "id": rid,
                "action": "upgrade",
                "actor": "operator",
                "version": "v9.9.9",
            }
            (results / f"{RID}.json").write_text('{"status":"applied"}')
            async with session.get(f"{process.url}/api/control/result?id={RID}") as response:
                assert response.status == 200
                assert (await response.json())["status"] == "applied"
    finally:
        await process.close()


async def test_missing_native_control_aborts_before_app_creation(tmp_path, monkeypatch):
    root = _web_root(tmp_path)
    package = tmp_path / "mining_dashboard"
    with (package / "__init__.py").open("a") as stream:
        stream.write("""
import sys
class BlockControl:
    def find_spec(self, fullname, path, target=None):
        if fullname == "mining_dashboard.go_control":
            raise ModuleNotFoundError(name=fullname)
sys.meta_path.insert(0, BlockControl())
""")
    marker = tmp_path / "app-created"
    (package / "main.py").write_text(
        "from aiohttp import web\nfrom pathlib import Path\nSHUTDOWN_TIMEOUT = 0.1\n"
        f"def build_app():\n    Path({str(marker)!r}).touch()\n    return web.Application()\n"
    )
    monkeypatch.delenv("PITHEAD_DASHBOARD_REFERENCE_URL", raising=False)
    process = DashboardProcess(None, True, web_root=root, python=PYTHON)
    try:
        with pytest.raises(RuntimeError, match="exited during startup"):
            await process.start()
        assert not marker.exists()
    finally:
        await process.close()
