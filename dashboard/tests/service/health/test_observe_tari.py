"""DataSetupMixin._observe_tari (#2464): a failed health cycle keeps the last verdict visible."""

import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

from mining_dashboard.service import data_setup
from mining_dashboard.service.data_setup import DataSetupMixin


def _host(check):
    return SimpleNamespace(
        tari_chain=SimpleNamespace(check=check, verdict={"level": "red", "reasons": ["x"]}),
        tari_health=MagicMock(update=MagicMock(return_value=False)),
    )


def test_a_failed_health_cycle_serves_the_last_verdict(monkeypatch):
    monkeypatch.setattr(data_setup, "TARI_MODE", "local")
    host = _host(AsyncMock(side_effect=RuntimeError("boom")))
    client = MagicMock(get_connections=AsyncMock(return_value=0))
    sync = {"reachable": True, "current": 1}
    down = asyncio.run(DataSetupMixin._observe_tari(host, client, sync))
    assert sync["health"] == {"level": "red", "reasons": ["x"]}
    assert down is False  # node-down still updated after the failure
    host.tari_health.update.assert_called_once_with(True)


def test_off_mode_judges_nothing(monkeypatch):
    monkeypatch.setattr(data_setup, "TARI_MODE", "off")
    host = _host(AsyncMock())
    sync = {"reachable": False}
    asyncio.run(DataSetupMixin._observe_tari(host, MagicMock(), sync))
    assert "health" not in sync
    host.tari_chain.check.assert_not_awaited()
    host.tari_health.update.assert_not_called()


def test_the_verdict_is_attached_for_the_panel_doctor_and_status(monkeypatch):
    monkeypatch.setattr(data_setup, "TARI_MODE", "local")
    host = _host(AsyncMock(return_value={"level": "red", "reasons": ["x"]}))
    sync = {"reachable": True, "current": 1}
    client = MagicMock(get_connections=AsyncMock(return_value=0))
    asyncio.run(DataSetupMixin._observe_tari(host, client, sync))
    assert sync["health"] == {"level": "red", "reasons": ["x"]}
    host.tari_chain.check.assert_awaited_once_with(sync, 0)
