"""Healthchecks ping: fresh-circuit retry, deadline and the independent ping task."""

import asyncio
import time
from unittest.mock import MagicMock, patch

import requests

import mining_dashboard.service.notify.healthchecks as hc_mod
from mining_dashboard.service.notify.healthchecks import HealthchecksClient


def _client(**overrides):
    cfg = dict(ping_url="https://hc-ping.com/abc", interval_seconds=60)
    cfg.update(overrides)
    return HealthchecksClient(**cfg)


def _resp(status_code):
    r = MagicMock()
    r.status_code = status_code
    return r


class TestFreshCircuitRetry:
    def _tor_client(self, **overrides):
        return _client(tor_proxy="socks5h://tor:9050", **overrides)

    def test_a_failed_ping_is_retried_once_on_an_isolated_circuit(self):
        rows = []
        c = self._tor_client(record_failure=lambda ts, reason, detail: rows.append(reason))
        err = requests.exceptions.ConnectionError("dead circuit")
        with patch.object(hc_mod, "bounded_get", side_effect=[err, _resp(200)]) as get:
            assert c.ping() is True
        first, second = (call.kwargs["proxies"]["https"] for call in get.call_args_list)
        assert first == "socks5h://tor:9050"
        auth = second.removeprefix("socks5h://").split("@")[0]
        user, _, password = auth.partition(":")
        assert len(user) == 32 and password == "isolate"
        assert rows == ["tor_socks"]

    def test_both_failed_attempts_are_recorded_on_distinct_circuits(self):
        rows = []
        c = self._tor_client(record_failure=lambda ts, reason, detail: rows.append(reason))
        err = requests.exceptions.ConnectTimeout("slow")
        with patch.object(hc_mod, "bounded_get", side_effect=[err, err]) as get:
            assert c.ping() is False
        assert get.call_count == 2
        assert rows == ["tor_socks", "tor_socks"]

    def test_each_ping_uses_a_new_circuit(self):
        c = self._tor_client(interval_seconds=0)
        err = requests.exceptions.ConnectionError("x")
        with patch.object(hc_mod, "bounded_get", side_effect=[err, err, err, err]) as get:
            c.ping()
            c.ping()
        retries = {get.call_args_list[i].kwargs["proxies"]["https"] for i in (1, 3)}
        assert len(retries) == 2

    def test_a_rejection_is_not_retried(self):
        c = self._tor_client()
        with patch.object(hc_mod, "bounded_get", return_value=_resp(404)) as get:
            assert c.ping() is False
        assert get.call_count == 1

    def test_every_attempt_carries_a_total_deadline_within_thirty_seconds(self):
        c = self._tor_client()
        with patch.object(hc_mod, "bounded_get", return_value=_resp(200)) as get:
            c.ping()
        kwargs = get.call_args.kwargs
        assert kwargs["deadline"] + kwargs["timeout"] <= 30


class TestIndependentTask:
    async def test_run_pings_every_interval_whatever_the_data_loop_does(self):
        c = _client()
        c.interval = 0.05
        calls = []
        with patch.object(c, "ping", side_effect=lambda: calls.append(1) or True):
            task = asyncio.create_task(c.run())
            await asyncio.sleep(0.3)
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        assert len(calls) >= 3

    async def test_a_hung_ping_does_not_stop_the_next_one(self):
        c = _client()
        c.interval = 0.05
        calls = []

        def ping():
            calls.append(1)
            if len(calls) == 1:
                time.sleep(0.5)
            return True

        with (
            patch.object(hc_mod, "_PING_CYCLE_LIMIT_SEC", 0.1),
            patch.object(c, "ping", side_effect=ping),
        ):
            task = asyncio.create_task(c.run())
            await asyncio.sleep(0.4)
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        assert len(calls) >= 2

    async def test_a_raising_ping_does_not_end_the_task(self):
        c = _client()
        c.interval = 0.05
        with patch.object(c, "ping", side_effect=RuntimeError("boom")) as ping:
            task = asyncio.create_task(c.run())
            await asyncio.sleep(0.3)
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        assert ping.call_count >= 2

    async def test_a_disabled_client_runs_no_task(self):
        c = _client(ping_url="")
        with patch.object(c, "ping") as ping:
            await asyncio.wait_for(c.run(), 1)
        ping.assert_not_called()
