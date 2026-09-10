# ruff: noqa: F401
import asyncio
import json
import uuid
from datetime import UTC, datetime
from unittest.mock import MagicMock

import pytest

from mining_dashboard.service import audit_service, control_service
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web.server import _apply_security_headers, create_app

SECURITY_HEADERS = [
    "X-Content-Type-Options",
    "X-Frame-Options",
    "Referrer-Policy",
    "Content-Security-Policy",
]


def _fresh_version(version):
    return {"version": version, "generated_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")}


@pytest.fixture
def app_data():
    """A realistic-ish latest_data snapshot."""
    return {
        "shares": [],
        "workers": [],
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 50, "current": 5, "target": 10},
        "global_sync": False,
    }


@pytest.fixture
async def client(aiohttp_client, app_data):
    sm = StateManager(db_path=":memory:")
    app = create_app(sm, app_data)
    cli = await aiohttp_client(app)
    yield cli
    sm.close()


@pytest.fixture
def control_spool(tmp_path, monkeypatch):
    """Enable the control channel and point the service at throwaway spool dirs."""
    host_config = tmp_path / "config.json"
    host_config.write_text(
        json.dumps(
            {
                "p2pool": {"pool": "mini"},
                "dashboard": {"auth": {"username": "admin", "password": "correct horse"}},
                "healthchecks": {"ping_url": "https://hc-ping.com/SECRET-UUID"},
            }
        )
    )
    (tmp_path / "requests").mkdir()
    (tmp_path / "results").mkdir()
    monkeypatch.setattr(control_service.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", str(host_config))
    monkeypatch.setattr(
        control_service.config, "HOST_REFERENCE_PATH", str(tmp_path / "no-reference.json")
    )
    monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", str(tmp_path / "requests"))
    monkeypatch.setattr(control_service.config, "CONTROL_RESULTS_DIR", str(tmp_path / "results"))
    monkeypatch.setattr(control_service.config, "CONTROL_WAIT_S", 0.1)
    return tmp_path


@pytest.fixture
async def control_client(aiohttp_client, app_data, control_spool):
    sm = StateManager(db_path=":memory:")
    cli = await aiohttp_client(create_app(sm, app_data))
    yield cli
    sm.close()


CONTROL_HEADERS = {"X-Pithead-Control": "1"}


@pytest.fixture
async def worker_client(aiohttp_client, control_spool, monkeypatch):
    """Control channel on, one editable worker descriptor, and a worker in the live snapshot.

    Exposes the StateManager so tests can read back the config history the route records."""
    from mining_dashboard.config import config as cfg_mod
    from mining_dashboard.web.views import views

    monkeypatch.setattr(
        cfg_mod, "DASHBOARD_WORKERS", [{"name": "rig1", "host": "10.0.0.9", "control_port": 8082}]
    )
    data = {
        "workers": [
            {
                "name": "rig1",
                "ip": "10.0.0.9",
                "status": "online",
                "active_pool": "3333",
                "h60": 5100,
                "rigforge": _fresh_version("1.11.0"),
            }
        ]
    }
    sm = StateManager(db_path=":memory:")
    cli = await aiohttp_client(create_app(sm, data))
    cli.sm = sm  # for history assertions
    assert views.config is cfg_mod  # both modules share the one config object
    yield cli
    sm.close()


__all__ = [name for name in globals() if not name.startswith("__")]
