from unittest.mock import AsyncMock

from mining_dashboard.service.health.tor_heal import (
    BROKEN_AFTER_SEC,
    MAX_ATTEMPTS,
    NEWNYM_ATTEMPTS,
    PROBE_INTERVAL_SEC,
    TorEgressHealer,
)
from tests.service.health.test_tor_heal_refresh import SATURATED, _heal_patches, _run_rounds


def _fake_probe(outcomes):
    def probe():
        return outcomes[0], "test probe"

    return probe


async def test_guard_rotation_signature_never_restarts_tor(caplog):
    now = [1000.0]
    docker = AsyncMock()
    notify = AsyncMock()
    submits = []
    results = {"tor-newnym": {"status": "applied", "action": "tor-dropguards"}}
    healer = TorEgressHealer(
        docker,
        enabled=True,
        probe=lambda: (False, "test probe"),
        notify=notify,
        clock=lambda: now[0],
    )
    p_submit, p_result = _heal_patches(results, submits)
    with p_submit, p_result, caplog.at_level("WARNING", logger="TorHeal"):
        await healer.check()
        now[0] += BROKEN_AFTER_SEC
        await _run_rounds(healer, now, MAX_ATTEMPTS + 3)
    assert submits.count("tor-newnym") == NEWNYM_ATTEMPTS
    assert healer._guard_rotated is True
    docker.stop.assert_not_awaited()
    assert "tor-recover" not in submits
    assert any("Not restarting Tor" in r.message for r in caplog.records)


async def test_guard_rotation_on_saturated_history_does_not_request_state_recovery():
    now = [1000.0]
    submits = []
    results = {
        "tor-newnym": {"status": "applied", "action": "tor-dropguards"},
        "tor-history": SATURATED,
    }
    healer = TorEgressHealer(
        AsyncMock(), enabled=True, probe=lambda: (False, "test probe"), clock=lambda: now[0]
    )
    p_submit, p_result = _heal_patches(results, submits)
    with p_submit, p_result:
        await healer.check()
        now[0] += BROKEN_AFTER_SEC
        await _run_rounds(healer, now, MAX_ATTEMPTS + 3)
    assert "tor-recover" not in submits


async def test_recovered_egress_after_rotation_clears_the_restart_ban():
    now = [1000.0]
    ok = [False]
    notify = AsyncMock()
    submits = []
    results = {"tor-newnym": {"status": "applied", "action": "tor-dropguards"}}
    healer = TorEgressHealer(
        AsyncMock(), enabled=True, probe=_fake_probe(ok), notify=notify, clock=lambda: now[0]
    )
    p_submit, p_result = _heal_patches(results, submits)
    with p_submit, p_result:
        await healer.check()
        now[0] += BROKEN_AFTER_SEC
        await healer.check()
        now[0] += PROBE_INTERVAL_SEC
        await healer.check()
        assert healer._guard_rotated is True
        ok[0] = True
        for _ in range(2):
            now[0] += PROBE_INTERVAL_SEC
            await healer.check()
    assert healer._guard_rotated is False
    assert "guard rotation" in notify.await_args.args[0]


async def test_circuits_completing_means_no_action():
    now = [1000.0]
    submits = []
    healer = TorEgressHealer(
        AsyncMock(), enabled=True, probe=lambda: (True, "answered"), clock=lambda: now[0]
    )
    p_submit, p_result = _heal_patches({}, submits)
    with p_submit, p_result:
        await _run_rounds(healer, now, 4)
    assert submits == []
    assert (healer._attempts, healer._failing_since) == (0, None)
    healer._docker.stop.assert_not_awaited()
    assert healer._guard_rotated is False
