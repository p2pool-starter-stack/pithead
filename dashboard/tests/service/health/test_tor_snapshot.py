from unittest.mock import AsyncMock, patch

import pytest

from mining_dashboard.service.health.tor_heal import (
    BROKEN_AFTER_SEC,
    COOLDOWN_SEC,
    TorEgressHealer,
)
from mining_dashboard.service.health.tor_snapshot import snapshot_line

SNAP = {
    "taken_at": 1000,
    "control": "ok",
    "version": "0.4.9.17",
    "bootstrap": {"progress": 100, "tag": "done", "changed_at": 900},
    "circuits": [{"state": "LAUNCHED", "purpose": "HS_SERVICE_HSDIR", "count": 12}],
    "guards": {"up": 2, "down": 1},
    "consensus": {"source": "control", "valid_after": 0, "valid_until": 1, "age_sec": 7200},
}


def test_snapshot_line_names_every_field():
    assert snapshot_line(SNAP, now=1600) == (
        "Tor snapshot taken 10 min ago: control ok; version 0.4.9.17; bootstrap 100% (done); "
        "consensus age 120 min (control); guards down 1, up 2; circuits LAUNCHED HS_SERVICE_HSDIR 12."
    )


def test_snapshot_line_reports_unreachable_and_missing_data():
    line = snapshot_line({"control": "unreachable", "consensus": {"source": "none"}})
    assert line == (
        "Tor snapshot: control unreachable; version unknown; bootstrap ?%; "
        "consensus age unknown (none); guards none; circuits none."
    )
    assert snapshot_line(None) == ""


@pytest.mark.parametrize("saturated", [True, False])
async def test_heal_alerts_carry_the_snapshot_from_the_history_round(saturated):
    now = [1000.0]
    docker = AsyncMock()
    docker.stop.return_value = docker.start.return_value = True
    notify = AsyncMock(return_value=True)
    probe = {"ok": False}
    healer = TorEgressHealer(
        docker,
        enabled=True,
        restart_monerod=False,
        probe=lambda: (probe["ok"], "isolated failures"),
        clock=lambda: now[0],
        notify=notify,
    )
    results = {
        "tor-history": {"status": "applied", "saturated": saturated, "tor": SNAP},
        "tor-newnym": {"status": "applied"},
        "tor-recover": {"status": "applied"},
    }
    with (
        patch("mining_dashboard.service.control_service.submit", lambda action, **kw: action),
        patch("mining_dashboard.service.control_service.result", lambda rid: results.get(rid)),
        patch("mining_dashboard.service.request_spool.write", lambda req: req["action"]),
    ):
        await healer.check()
        now[0] += BROKEN_AFTER_SEC
        await healer.check()
        for _ in range(3):
            now[0] += COOLDOWN_SEC
            await healer.check()
        probe["ok"] = True
        for _ in range(2):
            now[0] += COOLDOWN_SEC
            await healer.check()
    assert healer.tor_snapshot == SNAP
    texts = [c.args[0] for c in notify.await_args_list]
    assert texts, "the heal round sent no alert"
    assert any("recovered" in t for t in texts)
    for text in texts:
        assert "Tor snapshot" in text
        assert "circuits LAUNCHED HS_SERVICE_HSDIR 12" in text
