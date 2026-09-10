# ruff: noqa: F401
import asyncio
import json
import time
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

import mining_dashboard.service.data_service as ds_mod
from mining_dashboard.client.xmrig_client import XMRigWorkerClient
from mining_dashboard.client.xvb_client import (
    REG_ERROR,
    REG_INVALID,
    REG_NOT_ELIGIBLE,
    REG_OK,
)
from mining_dashboard.config.config import XVB_REGISTER_INTERVAL_S
from mining_dashboard.service.data_helpers import (
    _iso_now,
    _normalize_proxy_workers,
    _parse_audit_ts,
)
from mining_dashboard.service.data_service import (
    _XVB_REGISTER_FAIL_ALERT,
    DataService,
)


class _FakeClientSession:
    """Stand-in for aiohttp.ClientSession used as an async context manager."""

    async def __aenter__(self):
        return MagicMock()

    async def __aexit__(self, *exc):
        return False


def _make_service():
    state_manager = MagicMock()
    state_manager.load_snapshot.return_value = None
    state_manager.get_shares.return_value = []
    state_manager.get_xvb_stats.return_value = {"current_mode": "P2POOL"}
    proxy_client = MagicMock()
    xvb_client = MagicMock()
    svc = DataService(state_manager, proxy_client, xvb_client)
    # Mock the docker-control proxy so run()'s sync gate / failover don't hit the network.
    svc.docker_control = MagicMock()
    svc.docker_control.stop = AsyncMock(return_value=True)
    svc.docker_control.start = AsyncMock(return_value=True)
    return svc, state_manager, proxy_client


class _RecordingGet:
    """One aiohttp ``session.get()`` async-context-manager that records nothing itself."""

    async def __aenter__(self):
        resp = MagicMock()
        resp.status = 200
        resp.content.read = AsyncMock(side_effect=[json.dumps({"ok": True}).encode(), b""])
        return resp

    async def __aexit__(self, *exc):
        return False


class _RecordingSession:
    """Minimal aiohttp ClientSession stub that records every probed URL."""

    def __init__(self):
        self.urls = []

    def get(self, url, headers=None, timeout=None):
        self.urls.append(url)
        return _RecordingGet()


__all__ = [name for name in globals() if not name.startswith("__")]
