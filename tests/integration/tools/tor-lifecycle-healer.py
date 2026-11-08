import asyncio
import logging

from mining_dashboard.client.docker.docker_control import DockerControl
from mining_dashboard.service.health.tor_heal import (
    BROKEN_AFTER_SEC,
    COOLDOWN_SEC,
    MAX_ATTEMPTS,
    TorEgressHealer,
)


async def main():
    now = COOLDOWN_SEC * 10
    healer = TorEgressHealer(
        DockerControl(),
        enabled=True,
        probe=lambda: (False, "receipt fixture"),
        clock=lambda: now,
        restart_monerod=False,
    )
    healer._failing_since = now - BROKEN_AFTER_SEC
    healer._attempts = MAX_ATTEMPTS - 1
    healer._last_attempt = now - COOLDOWN_SEC
    await healer.check()
    if healer._recovery_step != "Tor restart":
        raise RuntimeError("healer did not confirm its real stop/start")
    healer.CONTAINER = "pithead-receipt-missing"
    if await healer._tor_call("start"):
        raise RuntimeError("missing-container call unexpectedly succeeded")


logging.basicConfig(level=logging.INFO, format="%(message)s")
asyncio.run(main())
