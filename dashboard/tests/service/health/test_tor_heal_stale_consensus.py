import fcntl
from unittest.mock import AsyncMock, patch

from mining_dashboard.service.health import tor_heal_history
from mining_dashboard.service.health.tor_heal import PROBE_INTERVAL_SEC, TorEgressHealer
from mining_dashboard.service.health.tor_heal_history import (
    MAX_DISRUPTIVE_PER_DAY,
    OBSERVE_INTERVAL_SEC,
    STALE_RETRY_SEC,
)


class Host:
    def __init__(self, stale):
        self.stale = stale
        self.requests = []
        self.submits = []

    def write(self, request):
        self.requests.append(request)
        return f"read-{len(self.requests)}"

    def submit(self, action, **_):
        self.submits.append(action)
        return "recover"

    def result(self, request_id):
        if request_id == "recover":
            return {"status": "applied"}
        return {
            "status": "applied",
            "saturated": False,
            "consensus_stale": self.stale,
            "consensus_age_sec": 61200 if self.stale else 600,
        }


def make(host, peerless=None):
    now = [1000.0]
    healer = TorEgressHealer(
        AsyncMock(),
        enabled=True,
        restart_monerod=False,
        probe=lambda: (True, "probe answered"),
        clock=lambda: now[0],
        peerless_since=peerless,
    )
    healer._jitter = lambda low, high: 0
    healer._observe_next = 0
    healer._host_lock_free = lambda: True
    patches = (
        patch("mining_dashboard.service.control_service.submit", host.submit),
        patch("mining_dashboard.service.control_service.result", host.result),
        patch("mining_dashboard.service.request_spool.write", host.write),
    )
    return healer, now, patches


async def cycle(healer, now, count):
    for _ in range(count):
        now[0] += PROBE_INTERVAL_SEC
        await healer.check()


async def test_stale_consensus_requests_one_recovery_within_the_cooldown(caplog):
    host = Host(stale=True)
    healer, now, patches = make(host)
    with patches[0], patches[1], patches[2], caplog.at_level("WARNING", logger="TorHeal"):
        await cycle(healer, now, 6)
    assert host.submits == ["tor-recover"]
    assert host.requests[0]["outage"] == ""
    assert healer._attempts == 0
    assert any("61200 s old" in r.getMessage() for r in caplog.records)


async def test_fresh_consensus_never_requests_recovery():
    host = Host(stale=False)
    healer, now, patches = make(host)
    with patches[0], patches[1], patches[2]:
        await cycle(healer, now, 6)
    assert host.submits == []
    assert host.requests


async def test_stale_consensus_retries_only_after_the_host_cooldown():
    host = Host(stale=True)
    healer, now, patches = make(host)
    with patches[0], patches[1], patches[2]:
        await cycle(healer, now, 3)
        now[0] += STALE_RETRY_SEC
        await cycle(healer, now, 3)
    assert host.submits == ["tor-recover", "tor-recover"]


async def test_stale_consensus_honours_the_daily_disruptive_cap():
    host = Host(stale=True)
    healer, now, patches = make(host)
    healer._disruptive = [now[0]] * MAX_DISRUPTIVE_PER_DAY
    with patches[0], patches[1], patches[2]:
        await cycle(healer, now, 3)
    assert host.submits == []


async def test_stale_consensus_waits_for_its_jitter():
    host = Host(stale=True)
    healer, now, patches = make(host)
    healer._jitter = lambda low, high: 2 * PROBE_INTERVAL_SEC
    with patches[0], patches[1], patches[2]:
        await cycle(healer, now, 2)
        assert host.submits == []
        await cycle(healer, now, 2)
    assert host.submits == ["tor-recover"]


async def test_peerless_tari_with_passing_probes_is_logged_with_cache_age(caplog):
    host = Host(stale=False)
    healer, now, patches = make(host, peerless=lambda: 0.0)
    with patches[0], patches[1], patches[2], caplog.at_level("WARNING", logger="TorHeal"):
        await cycle(healer, now, 3)
    assert host.submits == []
    messages = [r.getMessage() for r in caplog.records if "Tari has had no peers" in r.getMessage()]
    assert len(messages) == 1
    assert "600 s" in messages[0]


async def test_healthy_probes_read_the_cache_age_once_per_observe_interval():
    host = Host(stale=False)
    healer, now, patches = make(host)
    with patches[0], patches[1], patches[2]:
        await cycle(healer, now, OBSERVE_INTERVAL_SEC // PROBE_INTERVAL_SEC)
        assert len(host.requests) == 1
        await cycle(healer, now, 1)
    assert len(host.requests) == 2


async def test_the_first_observation_waits_one_interval_after_start():
    host = Host(stale=True)
    healer, now, patches = make(host)
    healer._observe_next = None
    with patches[0], patches[1], patches[2]:
        await cycle(healer, now, 1)
        assert host.requests == []
        await cycle(healer, now, OBSERVE_INTERVAL_SEC // PROBE_INTERVAL_SEC)
    assert len(host.requests) == 1


def _hold(path):
    path.write_bytes(b"")
    held = path.open("rb")
    fcntl.flock(held, fcntl.LOCK_EX)
    return held


async def test_a_held_host_lock_defers_the_observation(tmp_path):
    lock_path = tmp_path / "lock"
    held = _hold(lock_path)
    host = Host(stale=False)
    healer, now, patches = make(host)
    del healer._host_lock_free
    with (
        patches[0],
        patches[1],
        patches[2],
        patch.object(tor_heal_history, "HOST_LOCK_FILE", str(lock_path)),
    ):
        await cycle(healer, now, 1)
        assert host.requests == []
        held.close()
        await cycle(healer, now, 1)
    assert len(host.requests) == 1
