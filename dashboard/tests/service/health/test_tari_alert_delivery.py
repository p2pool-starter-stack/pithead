"""Tari chain alerts through the real one-off sender (#2464 review round 12): a sink that reports
failure is not delivery, so the red alert is retried while red and no recovery note follows a red
that never got out."""

import asyncio

from mining_dashboard.service.health.tari_health import TariChainHealth
from tests.service.health.test_tari_health import MIN, SYNCED, Clock
from tests.service.notify._alert_service_support import _svc


class Sink:
    """A webhook/ntfy/Telegram-shaped sink: ``send`` returns True only on success, never raises."""

    enabled = True

    def __init__(self, ok=False):
        self.ok = ok
        self.attempts = []

    def event_enabled(self, event):
        return True

    def send(self, text, event=""):
        self.attempts.append(text)
        return self.ok


def _monitor(*sinks):
    svc = _svc(notifier=sinks[0], sinks=list(sinks))
    clock = Clock()
    return TariChainHealth(explorer_url="", notify=svc.tor_heal_alert, clock=clock), clock


def _cycles(mon, clock, n, sync=SYNCED, connections=0):
    for _ in range(n):
        asyncio.run(mon.check(sync, connections))
        clock.t += MIN


def _red(sink):
    return [t for t in sink.attempts if "not following the chain" in t]


def _recovery(sink):
    return [t for t in sink.attempts if "following the chain again" in t]


def test_every_sink_failing_is_not_delivery_and_red_is_retried_each_cycle():
    a, b = Sink(ok=False), Sink(ok=False)
    mon, clock = _monitor(a, b)
    _cycles(mon, clock, 35)  # minutes 0-34, red from minute 30: five red cycles
    assert len(_red(a)) == len(_red(b)) == 5


def test_a_red_retry_that_succeeds_is_sent_once_and_then_recovery_follows():
    sink = Sink(ok=False)
    mon, clock = _monitor(sink)
    _cycles(mon, clock, 33)
    sink.ok = True
    _cycles(mon, clock, 5)
    assert len(_red(sink)) == 4  # three failures retried, then one delivery, then no more
    _cycles(mon, clock, 1, sync={**SYNCED, "current": SYNCED["current"] + 1}, connections=5)
    assert len(_recovery(sink)) == 1


def test_one_sink_delivering_is_delivery():
    bad, good = Sink(ok=False), Sink(ok=True)
    mon, clock = _monitor(bad, good)
    _cycles(mon, clock, 35)
    assert len(_red(good)) == 1


def test_no_recovery_note_after_a_red_that_no_sink_delivered():
    sink = Sink(ok=False)
    mon, clock = _monitor(sink)
    _cycles(mon, clock, 33)
    sink.ok = True
    _cycles(mon, clock, 1, sync={**SYNCED, "current": SYNCED["current"] + 1}, connections=5)
    assert _recovery(sink) == []
