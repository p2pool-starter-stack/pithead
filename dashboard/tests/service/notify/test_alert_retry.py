import asyncio
from unittest.mock import patch

from mining_dashboard.service.notify import alert_retry
from mining_dashboard.service.notify.alert_retry import (
    RETRY_EVERY_S,
    RETRY_FIRST_S,
    RETRY_MAX_AGE_S,
    RETRY_MAX_PENDING,
)
from mining_dashboard.service.notify.alert_service import AlertService


class Sink:
    enabled = True

    def __init__(self, results=(), events=None):
        self.results = list(results)
        self.events = events
        self.sent = []

    def event_enabled(self, event):
        return self.events is None or event in self.events

    def send(self, text, event=""):
        self.sent.append(text)
        return self.results.pop(0) if self.results else True


def send(svc, at, *alerts):
    with patch.object(alert_retry.time, "monotonic", return_value=at):
        asyncio.run(svc._outbox.send(list(alerts), svc._event_sinks))


def test_a_failed_alert_is_retried_once_the_first_wait_has_passed():
    sink = Sink([False])
    svc = AlertService(sinks=[sink])
    send(svc, 0, ("node_down", "down"))
    send(svc, RETRY_FIRST_S - 1)
    assert sink.sent == ["down"]
    send(svc, RETRY_FIRST_S)
    assert sink.sent == ["down", "down"]
    send(svc, 10 * RETRY_EVERY_S)
    assert sink.sent == ["down", "down"]


def test_the_wait_doubles_up_to_the_limit_and_resets_after_a_delivery():
    sink = Sink([False] * 6)
    svc = AlertService(sinks=[sink])
    at, waits = 0, []
    send(svc, at, ("node_down", "down"))
    for _ in range(5):
        waits.append(svc._outbox._retry_at - at)
        at = svc._outbox._retry_at
        send(svc, at)
    assert waits == [30, 60, 120, 240, RETRY_EVERY_S]
    send(svc, svc._outbox._retry_at)
    assert svc._outbox.pending == [] and svc._outbox._wait == 0


def test_a_new_alert_sends_the_older_one_first():
    sink = Sink([False])
    svc = AlertService(sinks=[sink])
    send(svc, 0, ("node_down", "down"))
    send(svc, 1, ("node_recovered", "recovered"))
    assert sink.sent == ["down", "down", "recovered"]


def test_a_dead_sink_is_tried_once_per_round():
    sink = Sink([False] * 9)
    svc = AlertService(sinks=[sink])
    send(svc, 0, *[("node_down", str(i)) for i in range(5)])
    assert sink.sent == ["0"]
    assert [text for _, text, _ in svc._outbox.pending] == ["0", "1", "2", "3", "4"]


def test_an_alert_one_sink_accepted_is_done():
    good, bad = Sink(), Sink([False])
    svc = AlertService(sinks=[good, bad])
    send(svc, 0, ("node_down", "down"))
    send(svc, RETRY_EVERY_S)
    assert good.sent == ["down"] and bad.sent == ["down"]
    assert svc._outbox.pending == []


def test_an_alert_older_than_the_age_limit_is_dropped():
    sink = Sink([False])
    svc = AlertService(sinks=[sink])
    send(svc, 0, ("node_down", "down"))
    send(svc, RETRY_MAX_AGE_S + 1)
    assert sink.sent == ["down"]
    assert svc._outbox.pending == []


def test_an_alert_whose_sinks_are_all_switched_off_is_dropped():
    sink = Sink([False], events={"node_down"})
    svc = AlertService(sinks=[sink])
    send(svc, 0, ("node_down", "down"))
    sink.events = set()
    send(svc, RETRY_FIRST_S)
    assert sink.sent == ["down"]
    assert svc._outbox.pending == []


def test_the_queue_is_bounded():
    sink = Sink([False])
    svc = AlertService(sinks=[sink])
    send(svc, 0, *[("node_down", str(i)) for i in range(RETRY_MAX_PENDING + 20)])
    assert len(svc._outbox.pending) == RETRY_MAX_PENDING
    assert svc._outbox.pending[-1][1] == str(RETRY_MAX_PENDING + 19)


def test_process_delivers_a_node_down_alert_after_the_sink_recovers():
    sink = Sink([False])
    svc = AlertService(sinks=[sink])
    svc.evaluate = lambda **kw: [("node_down", "down")] if kw.get("first") else []
    with patch.object(alert_retry.time, "monotonic", return_value=0):
        asyncio.run(svc.process(first=True))
    with patch.object(alert_retry.time, "monotonic", return_value=RETRY_FIRST_S):
        asyncio.run(svc.process())
        asyncio.run(svc.process())
    assert sink.sent == ["down", "down"]


def test_process_still_retries_while_evaluation_keeps_failing(caplog):
    sink = Sink([False])
    svc = AlertService(sinks=[sink])
    svc.evaluate = lambda **kw: [("node_down", "down")]
    with patch.object(alert_retry.time, "monotonic", return_value=0):
        asyncio.run(svc.process())
    svc.evaluate = lambda **kw: 1 / 0
    with (
        caplog.at_level("WARNING"),
        patch.object(alert_retry.time, "monotonic", return_value=RETRY_FIRST_S),
    ):
        assert asyncio.run(svc.process()) == []
    assert sink.sent == ["down", "down"]
    assert "Alert evaluation failed (ZeroDivisionError)" in caplog.text
