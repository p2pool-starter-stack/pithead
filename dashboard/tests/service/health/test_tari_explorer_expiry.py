import asyncio

from mining_dashboard.service.health import tari_health as th
from mining_dashboard.service.health.tari_health import TariChainHealth
from tests.service.health.test_tari_health import SYNCED, Clock

HOUR = th.EXPLORER_INTERVAL_SEC
AHEAD = SYNCED["current"] + 98
LEVEL = SYNCED["current"] + 1


def _scenario(tips):
    clock, sent = Clock(), []
    queue = list(tips)

    async def notify(text):
        sent.append(text)
        return text

    mon = TariChainHealth(
        explorer_url="https://example.invalid/?json",
        explorer=lambda url: queue.pop(0),
        notify=notify,
        clock=clock,
    )
    levels = []
    for i, _ in enumerate(tips):
        sync = {**SYNCED, "current": SYNCED["current"] + i}
        levels.append(asyncio.run(mon.check(sync, 4))["level"])
        clock.t += HOUR
    alerts = [t for t in sent if "not following the chain" in t]
    recoveries = [t for t in sent if "following the chain again" in t]
    return levels, len(alerts), len(recoveries)


def test_one_failed_fetch_keeps_the_lag_red_and_sends_no_recovery():
    assert _scenario([AHEAD, None, AHEAD]) == (["red", "red", "red"], 1, 0)


def test_two_failed_fetches_expire_the_reference_without_a_recovery_message():
    assert _scenario([AHEAD, None, None, None]) == (["red", "red", "green", "green"], 1, 0)


def test_a_good_fetch_after_expiry_that_shows_no_lag_sends_the_recovery():
    assert _scenario([AHEAD, None, None, LEVEL + 3]) == (["red", "red", "green", "green"], 1, 1)


def test_a_good_fetch_after_expiry_that_still_shows_lag_does_not_alert_twice():
    assert _scenario([AHEAD, None, None, AHEAD]) == (["red", "red", "green", "red"], 1, 0)


def test_a_good_fetch_without_lag_still_sends_the_recovery():
    assert _scenario([AHEAD, LEVEL]) == (["red", "green"], 1, 1)
