from unittest.mock import AsyncMock, patch

from mining_dashboard.service.health.monerod_redial import MonerodRestartBudget
from mining_dashboard.service.health.tor_heal import COOLDOWN_SEC, MAX_ATTEMPTS, TorEgressHealer
from tests.service.health.test_tor_heal import _Clock, _FakeDocker

TARGET = "mining_dashboard.service.health.tor_heal"


async def _heal_to_the_restart(budget, docker, clock):
    healer = TorEgressHealer(
        docker,
        enabled=True,
        probe=lambda: (False, "test probe"),
        clock=clock,
        monerod_budget=budget,
    )
    with (
        patch(f"{TARGET}.control_service.submit", return_value="id"),
        patch(f"{TARGET}.control_service.result", return_value={"status": "applied"}),
        patch(
            f"{TARGET}.get_container_health",
            AsyncMock(return_value={"monerod": {"running": True}}),
        ),
    ):
        await healer.check()
        for _ in range(MAX_ATTEMPTS + 1):
            clock.t += COOLDOWN_SEC
            await healer.check()


async def test_the_heal_cycles_monerod_from_the_shared_budget():
    clock = _Clock()
    docker = _FakeDocker()
    budget = MonerodRestartBudget()
    await _heal_to_the_restart(budget, docker, clock)
    assert docker.calls[-2:] == [("stop", "monerod"), ("start", "monerod")]
    assert budget.count() == 1
    assert not budget.allow(clock.t)


async def test_a_held_shared_budget_spares_monerod_the_restart():
    clock = _Clock()
    docker = _FakeDocker()
    budget = MonerodRestartBudget()
    budget.spend(clock.t + COOLDOWN_SEC * (MAX_ATTEMPTS + 1))
    await _heal_to_the_restart(budget, docker, clock)
    assert ("stop", "tor") in docker.calls
    assert ("stop", "monerod") not in docker.calls
    assert ("start", "monerod") not in docker.calls
