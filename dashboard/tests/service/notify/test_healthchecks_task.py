"""Healthchecks ping: fresh-circuit retry, deadline and the independent ping task."""

import asyncio
import socket
import threading
import time
from unittest.mock import MagicMock, patch

import pytest
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
        with patch.object(hc_mod, "_fetch", side_effect=[err, _resp(200)]) as get:
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
        with patch.object(hc_mod, "_fetch", side_effect=[err, err]) as get:
            assert c.ping() is False
        assert get.call_count == 2
        assert rows == ["tor_socks", "tor_socks"]

    def test_each_ping_uses_a_new_circuit(self):
        c = self._tor_client(interval_seconds=0)
        err = requests.exceptions.ConnectionError("x")
        with patch.object(hc_mod, "_fetch", side_effect=[err, err, err, err]) as get:
            c.ping()
            c.ping()
        retries = {get.call_args_list[i].kwargs["proxies"]["https"] for i in (1, 3)}
        assert len(retries) == 2

    def test_a_rejection_is_not_retried(self):
        c = self._tor_client()
        with patch.object(hc_mod, "_fetch", return_value=_resp(404)) as get:
            assert c.ping() is False
        assert get.call_count == 1


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


class _Server:
    def __init__(self, behaviour):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(4)
        self.port = self.sock.getsockname()[1]
        self.behaviour = behaviour
        self.stop = threading.Event()
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        self.sock.settimeout(0.2)
        while not self.stop.is_set():
            try:
                conn, _ = self.sock.accept()
            except OSError:
                continue
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        try:
            conn.recv(4096)
            if self.behaviour == "ok":
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
            else:
                while not self.stop.is_set():
                    conn.sendall(b"H" if self.behaviour == "trickle-headers" else b"x")
                    time.sleep(0.3)
        except OSError:
            pass
        finally:
            conn.close()

    def close(self):
        self.stop.set()
        self.sock.close()


class TestHardDeadline:
    def test_a_reply_is_read_through_the_child_process(self):
        srv = _Server("ok")
        try:
            resp = hc_mod._fetch(f"http://127.0.0.1:{srv.port}/p", timeout=5, deadline=5)
        finally:
            srv.close()
        assert resp.status_code == 200

    def test_a_header_trickle_is_cut_at_the_hard_limit(self):
        srv = _Server("trickle-headers")
        started = time.monotonic()
        try:
            with (
                patch.object(hc_mod, "_PING_HARD_LIMIT_SEC", 3),
                pytest.raises(requests.RequestException),
            ):
                hc_mod._fetch(f"http://127.0.0.1:{srv.port}/p", timeout=5, deadline=60)
        finally:
            srv.close()
        assert time.monotonic() - started < 8

    def test_a_ping_against_a_trickling_endpoint_ends_and_is_recorded(self):
        srv = _Server("trickle-headers")
        rows = []
        c = _client(
            ping_url=f"http://127.0.0.1:{srv.port}/p",
            record_failure=lambda ts, reason, detail: rows.append((reason, detail)),
        )
        started = time.monotonic()
        try:
            with patch.object(hc_mod, "_PING_HARD_LIMIT_SEC", 2):
                assert c.ping() is False
        finally:
            srv.close()
        assert time.monotonic() - started < 10
        assert rows == [("connect", "Timeout")] * 2

    def test_the_ping_url_never_reaches_the_child_command_line(self):
        with patch.object(hc_mod.subprocess, "run") as run:
            run.return_value = MagicMock(stdout='{"status": 200}')
            hc_mod._fetch("https://hc-ping.com/secret-token", timeout=5, deadline=5)
        assert "secret-token" not in " ".join(run.call_args.args[0])
        assert "secret-token" in run.call_args.kwargs["input"]

    def test_a_child_failure_keeps_its_reason_class(self):
        out = '{"reason": "dns", "name": "ConnectionError"}'
        with patch.object(hc_mod.subprocess, "run", return_value=MagicMock(stdout=out)):
            with pytest.raises(hc_mod.PingFailure) as err:
                hc_mod._fetch("https://hc-ping.com/x", timeout=5, deadline=5)
        assert (err.value.reason, err.value.name) == ("dns", "ConnectionError")

    def test_a_garbled_child_reply_is_a_connect_failure(self):
        with patch.object(hc_mod.subprocess, "run", return_value=MagicMock(stdout="")):
            with pytest.raises(hc_mod.PingFailure) as err:
                hc_mod._fetch("https://hc-ping.com/x", timeout=5, deadline=5)
        assert err.value.reason == "connect"


class TestFailingSince:
    def test_a_failed_ping_starts_a_streak_that_a_success_clears(self):
        c = _client(interval_seconds=0)
        err = requests.exceptions.ConnectionError("x")
        with patch.object(hc_mod, "_fetch", side_effect=[err, err, err, err, _resp(200)]):
            assert c.failing_since is None
            c.ping()
            first = c.failing_since
            assert first is not None
            c.ping()
            assert c.failing_since == first
            c.ping()
        assert c.failing_since is None
