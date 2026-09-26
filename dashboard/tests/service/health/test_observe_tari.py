"""DataSetupMixin._observe_tari (#2464): a failed health cycle keeps the last verdict visible."""

import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

from mining_dashboard.service import data_setup
from mining_dashboard.service.data_setup import DataSetupMixin


def _host(check):
    return SimpleNamespace(
        tari_chain=SimpleNamespace(
            check=check, verdict={"level": "red", "reasons": ["x"]}, advanced_at=None
        ),
        tari_merge_gate=SimpleNamespace(
            suppressed=True, apply=AsyncMock(return_value="suppressed")
        ),
        tari_health=MagicMock(update=MagicMock(return_value=False)),
        miner_released=True,
        miner_held=False,
        fail_closed_held=False,
    )


def test_a_failed_health_cycle_serves_the_last_verdict(monkeypatch):
    monkeypatch.setattr(data_setup, "TARI_MODE", "local")
    host = _host(AsyncMock(side_effect=RuntimeError("boom")))
    client = MagicMock(get_connections=AsyncMock(return_value=0))
    sync = {"reachable": True, "current": 1}
    down = asyncio.run(DataSetupMixin._observe_tari(host, client, sync))
    assert sync["health"] == {"level": "red", "reasons": ["x"], "merge_mining": "suppressed"}
    assert down is False  # node-down still updated after the failure
    host.tari_health.update.assert_called_once_with(True)


def test_off_mode_judges_nothing(monkeypatch):
    monkeypatch.setattr(data_setup, "TARI_MODE", "off")
    host = _host(AsyncMock())
    sync = {"reachable": False}
    asyncio.run(DataSetupMixin._observe_tari(host, MagicMock(), sync))
    assert "health" not in sync
    host.tari_chain.check.assert_not_awaited()


def test_the_gate_runs_on_the_verdict_and_knows_whether_p2pool_is_held(monkeypatch):
    monkeypatch.setattr(data_setup, "TARI_MODE", "local")
    host = _host(AsyncMock(return_value={"level": "red", "reasons": ["x"]}))
    host.fail_closed_held = True
    sync = {"reachable": True, "current": 1}
    asyncio.run(
        DataSetupMixin._observe_tari(
            host, MagicMock(get_connections=AsyncMock(return_value=0)), sync
        )
    )
    assert sync["health"]["merge_mining"] == "suppressed"
    assert host.tari_merge_gate.apply.await_args.args[2] is False  # held: no p2pool restart
