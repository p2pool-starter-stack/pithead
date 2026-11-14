"""Tests for the Healthchecks.io dead-man's-switch client (Issue #79)."""

import logging
from unittest.mock import MagicMock, patch

import requests

import mining_dashboard.service.notify.healthchecks as hc_mod
from mining_dashboard.service.notify.healthchecks import HealthchecksClient


class _Clock:
    """A controllable monotonic clock for throttle tests."""

    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def _client(clock=None, **overrides):
    cfg = dict(
        ping_url="https://hc-ping.com/abc",
        interval_seconds=60,
    )
    cfg.update(overrides)
    return HealthchecksClient(clock=clock or _Clock(), **cfg)


class TestUrlResolution:
    # Paste the full URL Healthchecks.io shows you (hosted or self-hosted); anything that isn't an
    # http(s) URL is treated as unset (base_url / bare-uuid support was dropped as redundant).
    def test_full_url_used_as_is(self):
        assert _client(ping_url="https://hc-ping.com/uuid").url == "https://hc-ping.com/uuid"

    def test_self_hosted_full_url_used_as_is(self):
        assert _client(ping_url="http://hc.local/ping/uuid").url == "http://hc.local/ping/uuid"

    def test_trailing_slash_stripped(self):
        assert _client(ping_url="https://hc-ping.com/uuid/").url == "https://hc-ping.com/uuid"

    def test_blank_or_none_is_unset(self):
        assert _client(ping_url="").url == ""
        assert _client(ping_url="   ").url == ""
        assert _client(ping_url=None).url == ""

    def test_bare_uuid_rejected_as_unset(self):
        assert _client(ping_url="abc-123").url == ""

    def test_enabled_is_derived_from_the_url(self):
        # No separate on/off flag: a URL means on, blank means off.
        assert _client(ping_url="https://hc-ping.com/abc").enabled is True
        assert _client(ping_url="").enabled is False


class TestPingUnconfigured:
    def test_no_url_is_a_silent_noop(self, caplog):
        # A blank ping URL is simply "off" — ping() does nothing, opens no socket, logs nothing.
        c = _client(ping_url="")
        with (
            patch.object(hc_mod, "bounded_get") as get,
            caplog.at_level(logging.DEBUG, logger="Healthchecks"),
        ):
            assert c.ping() is False
            assert c.ping() is False
        get.assert_not_called()
        assert not caplog.records


def _resp(status_code):
    r = MagicMock()
    r.status_code = status_code
    return r


class TestPingSuccess:
    def test_healthy_ping_hits_the_url(self):
        # Pure liveness: every ping hits the configured URL (no /fail path — health-aware was
        # dropped; node-health alerting is the Telegram alerter's job, #121).
        c = _client()
        with patch.object(hc_mod, "bounded_get", return_value=_resp(200)) as get:
            assert c.ping() is True
        get.assert_called_once()
        assert get.call_args.args[0] == "https://hc-ping.com/abc"


class TestPingRejected:
    """#560: a non-2xx response (revoked/typo'd ping URL) must not count as accepted."""

    def test_404_returns_false_and_does_not_advance_throttle(self, caplog):
        clock = _Clock(1000.0)
        c = _client(clock=clock, interval_seconds=60)
        with (
            patch.object(hc_mod, "bounded_get", return_value=_resp(404)),
            caplog.at_level(logging.WARNING, logger="Healthchecks"),
        ):
            assert c.ping() is False
            # Throttle didn't advance -> the very next cycle retries immediately.
            assert c.ping() is False
        assert [r for r in caplog.records if r.levelno == logging.WARNING and "404" in r.message]

    def test_200_still_returns_true_and_advances_throttle(self):
        # Regression guard: the happy path must keep working once status is checked.
        clock = _Clock(1000.0)
        c = _client(clock=clock, interval_seconds=60)
        with patch.object(hc_mod, "bounded_get", return_value=_resp(200)):
            assert c.ping() is True
            assert c.ping() is False  # throttled, since the first ping DID advance the clock
        clock.t += 61
        with patch.object(hc_mod, "bounded_get", return_value=_resp(200)):
            assert c.ping() is True

    def test_two_consecutive_404s_warn_only_once(self, caplog):
        clock = _Clock(1000.0)
        c = _client(clock=clock, interval_seconds=60)
        with (
            patch.object(hc_mod, "bounded_get", return_value=_resp(404)),
            caplog.at_level(logging.WARNING, logger="Healthchecks"),
        ):
            assert c.ping() is False
            assert c.ping() is False
        warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
        assert len(warnings) == 1

    def test_404_then_200_logs_recovery(self, caplog):
        clock = _Clock(1000.0)
        c = _client(clock=clock, interval_seconds=60)
        with caplog.at_level(logging.DEBUG, logger="Healthchecks"):
            with patch.object(hc_mod, "bounded_get", return_value=_resp(404)):
                assert c.ping() is False
            with patch.object(hc_mod, "bounded_get", return_value=_resp(200)):
                assert c.ping() is True
        recoveries = [r for r in caplog.records if "recovered" in r.message]
        assert len(recoveries) == 1
        assert recoveries[0].levelno == logging.INFO

    def test_5xx_also_rejected(self):
        c = _client()
        with patch.object(hc_mod, "bounded_get", return_value=_resp(503)):
            assert c.ping() is False


class TestTorRouting:
    def test_ping_passes_socks_proxies(self):
        # tor_proxy set → the ping rides the bridge Tor SOCKS (host IP hidden from the endpoint).
        proxy = "socks5h://172.28.0.25:9050"
        c = _client(tor_proxy=proxy)
        with patch.object(hc_mod, "bounded_get", return_value=_resp(200)) as get:
            assert c.ping() is True
        assert get.call_args.kwargs["proxies"] == {"http": proxy, "https": proxy}

    def test_from_config_always_routes_over_tor(self):
        # from_config wires the bridge Tor SOCKS unconditionally — there is no clearnet mode.
        with (
            patch.object(hc_mod, "HEALTHCHECKS_PING_URL", "https://hc-ping.com/zzz"),
            patch.object(hc_mod, "TOR_SOCKS_PROXY", "socks5h://172.28.0.25:9050"),
        ):
            c = HealthchecksClient.from_config()
        with patch.object(hc_mod, "bounded_get") as get:
            c.ping()
        assert get.call_args.kwargs["proxies"]["https"] == "socks5h://172.28.0.25:9050"


class TestThrottle:
    def test_second_immediate_ping_is_throttled(self):
        clock = _Clock(1000.0)
        c = _client(clock=clock, interval_seconds=60)
        with patch.object(hc_mod, "bounded_get", return_value=_resp(200)) as get:
            assert c.ping() is True  # first ping goes out
            assert c.ping() is False  # within the interval → skipped
        get.assert_called_once()

    def test_ping_again_after_interval_elapses(self):
        clock = _Clock(1000.0)
        c = _client(clock=clock, interval_seconds=60)
        with patch.object(hc_mod, "bounded_get", return_value=_resp(200)) as get:
            assert c.ping() is True
            clock.t += 61  # interval elapsed
            assert c.ping() is True
        assert get.call_count == 2

    def test_zero_interval_pings_every_call(self):
        clock = _Clock(1000.0)
        c = _client(clock=clock, interval_seconds=0)
        with patch.object(hc_mod, "bounded_get", return_value=_resp(200)) as get:
            assert c.ping() is True
            assert c.ping() is True
        assert get.call_count == 2


class TestPingFailsSilently:
    def test_network_error_is_swallowed_and_retries(self, caplog):
        clock = _Clock(1000.0)
        c = _client(clock=clock, interval_seconds=60)
        with (
            patch.object(
                hc_mod, "bounded_get", side_effect=requests.exceptions.ConnectionError("offline")
            ) as get,
            caplog.at_level(logging.DEBUG, logger="Healthchecks"),
        ):
            assert c.ping() is False
            # Throttle clock did NOT advance on failure → the very next call retries immediately.
            assert c.ping() is False
        assert get.call_count == 2
        # No noisy WARNING/ERROR — offline is expected and logged at debug only (#59 discipline).
        assert not [r for r in caplog.records if r.levelno >= logging.WARNING]

    def test_success_after_failure_advances_throttle(self):
        clock = _Clock(1000.0)
        c = _client(clock=clock, interval_seconds=60)
        with patch.object(
            hc_mod,
            "bounded_get",
            side_effect=[requests.exceptions.ConnectionError("x"), _resp(200)],
        ):
            assert c.ping() is False  # failed, no throttle advance
            assert c.ping() is True  # retried immediately, succeeded → throttle set
            assert c.ping() is False  # now throttled


class TestFromConfig:
    def test_defaults_to_disabled(self):
        # Real config defaults: no ping URL out of the box → off.
        assert HealthchecksClient.from_config().enabled is False

    def test_reads_config_values(self):
        with patch.object(hc_mod, "HEALTHCHECKS_PING_URL", "https://hc-ping.com/zzz"):
            c = HealthchecksClient.from_config()
        assert c.enabled is True  # a URL is configured
        assert c.url == "https://hc-ping.com/zzz"
        assert c.interval == hc_mod._PING_INTERVAL_SEC  # fixed throttle floor, not configurable


NameResolutionError = type("NameResolutionError", (Exception,), {})
gaierror = type("gaierror", (Exception,), {})
ProxyConnectionError = type("ProxyConnectionError", (Exception,), {})


class TestFailureRecording:
    URL = "https://hc-ping.com/secret-ping-token"

    def _client(self, recorder, **overrides):
        return _client(ping_url=self.URL, record_failure=recorder, **overrides)

    def _recorder(self):
        rows = []
        return rows, lambda ts, reason, detail: rows.append((ts, reason, detail))

    def _wrapped(self, inner, outer):
        exc = outer(f"while pinging {self.URL}")
        exc.__cause__ = inner
        return exc

    def test_a_success_records_nothing(self):
        rows, rec = self._recorder()
        with patch.object(hc_mod, "bounded_get", return_value=_resp(200)):
            assert self._client(rec).ping() is True
        assert rows == []

    def test_unconfigured_and_throttled_paths_record_nothing(self):
        rows, rec = self._recorder()
        assert _client(ping_url="", record_failure=rec).ping() is False
        assert rows == []
        clock = _Clock()
        c = self._client(rec, clock=clock)
        with patch.object(hc_mod, "bounded_get", return_value=_resp(200)):
            assert c.ping() is True
        rows.clear()
        with patch.object(hc_mod, "bounded_get", return_value=_resp(200)):
            assert c.ping() is False
        assert rows == []

    def test_rejection_is_recorded_as_http_status_with_the_status_in_detail(self):
        rows, rec = self._recorder()
        with patch.object(hc_mod, "bounded_get", return_value=_resp(404)):
            assert self._client(rec).ping() is False
        assert len(rows) == 1
        ts, reason, detail = rows[0]
        assert reason == "http_status"
        assert detail == "HTTP 404"
        assert ts > 1_600_000_000

    def test_proxy_error_maps_to_tor_socks(self):
        rows, rec = self._recorder()
        err = requests.exceptions.ProxyError(f"Cannot connect to proxy for {self.URL}")
        with patch.object(hc_mod, "bounded_get", side_effect=err):
            assert self._client(rec).ping() is False
        assert rows[0][1:] == ("tor_socks", "ProxyError")

    def test_wrapped_proxy_connection_error_maps_to_tor_socks(self):
        rows, rec = self._recorder()
        err = self._wrapped(
            ProxyConnectionError("proxy refused"), requests.exceptions.ConnectionError
        )
        with patch.object(hc_mod, "bounded_get", side_effect=err):
            assert self._client(rec).ping() is False
        assert rows[0][1] == "tor_socks"

    def test_name_resolution_maps_to_dns(self):
        rows, rec = self._recorder()
        err = self._wrapped(
            NameResolutionError("host not found"), requests.exceptions.ConnectionError
        )
        with patch.object(hc_mod, "bounded_get", side_effect=err):
            assert self._client(rec).ping() is False
        assert rows[0][1] == "dns"

    def test_gaierror_maps_to_dns(self):
        rows, rec = self._recorder()
        err = self._wrapped(gaierror("nodename nor servname"), requests.exceptions.ConnectionError)
        with patch.object(hc_mod, "bounded_get", side_effect=err):
            assert self._client(rec).ping() is False
        assert rows[0][1] == "dns"

    def test_a_class_two_hops_down_the_chain_still_maps(self):
        rows, rec = self._recorder()
        inner = NameResolutionError("host not found")
        middle = OSError(f"SSLError while reaching {self.URL}")
        middle.__cause__ = inner
        err = self._wrapped(middle, requests.exceptions.ConnectionError)
        with patch.object(hc_mod, "bounded_get", side_effect=err):
            assert self._client(rec).ping() is False
        assert rows[0][1] == "dns"

    def test_plain_connection_error_and_timeout_map_to_connect(self):
        rows, rec = self._recorder()
        with patch.object(
            hc_mod,
            "bounded_get",
            side_effect=[
                requests.exceptions.ConnectionError(f"reset by peer on {self.URL}"),
                requests.exceptions.Timeout(f"timed out against {self.URL}"),
            ],
        ):
            assert self._client(rec).ping() is False
            assert self._client(rec).ping() is False
        assert [r[1] for r in rows] == ["connect", "connect"]

    def test_no_stored_field_ever_contains_the_ping_url(self):
        rows, rec = self._recorder()
        errs = [
            requests.exceptions.ProxyError(f"Cannot connect to proxy for {self.URL}"),
            requests.exceptions.ConnectionError(f"reset by peer on {self.URL}"),
            requests.exceptions.Timeout(f"timed out against {self.URL}"),
        ]
        c = self._client(rec)
        for err in errs:
            with patch.object(hc_mod, "bounded_get", side_effect=err):
                assert c.ping() is False
        with patch.object(hc_mod, "bounded_get", return_value=_resp(403)):
            assert c.ping() is False
        assert len(rows) == 4
        for _ts, reason, detail in rows:
            assert self.URL not in str(detail)
            assert "secret-ping-token" not in f"{reason}{detail}"

    def test_a_recorder_that_raises_never_breaks_the_ping(self):
        def explode(ts, reason, detail):
            raise RuntimeError("db on fire")

        c = self._client(explode)
        with patch.object(hc_mod, "bounded_get", return_value=_resp(500)):
            assert c.ping() is False

    def test_from_config_threads_the_recorder_through(self):
        rows, rec = self._recorder()
        with patch.object(hc_mod, "HEALTHCHECKS_PING_URL", self.URL):
            c = HealthchecksClient.from_config(record_failure=rec)
        with patch.object(hc_mod, "bounded_get", return_value=_resp(500)):
            assert c.ping() is False
        assert rows[0][1:] == ("http_status", "HTTP 500")
