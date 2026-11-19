"""Tier 1 — bounded_get (#660): the shared response-size cap for external HTTP fetches."""

import re
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
import requests

from mining_dashboard.helper.http import (
    MAX_RESPONSE_BYTES,
    BoundedResponse,
    NoUsableProxy,
    ResponseTooLarge,
    bounded_get,
    bounded_read,
    bounded_request,
)

_PROXIES = {"http": "socks5h://tor.test:9050", "https": "socks5h://tor.test:9050"}


def _streaming_resp(chunks, status_code=200, encoding="utf-8"):
    resp = MagicMock(status_code=status_code, encoding=encoding)
    resp.iter_content.return_value = iter(chunks)
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False
    return resp


class TestBoundedGet:
    def test_under_cap_returns_body(self):
        with patch(
            "mining_dashboard.helper.http.requests.get",
            return_value=_streaming_resp([b'{"tag_nam', b'e": "v1.2.3"}']),
        ) as g:
            resp = bounded_get("https://example.test/x", timeout=20, proxies=_PROXIES)
        assert resp.status_code == 200
        assert resp.text == '{"tag_name": "v1.2.3"}'
        assert resp.json() == {"tag_name": "v1.2.3"}
        # The read is streamed, never buffered whole by requests itself.
        assert g.call_args.kwargs["stream"] is True

    def test_exactly_at_cap_returns_body(self):
        # The cap is strictly greater-than: a body of exactly max_bytes succeeds.
        with patch(
            "mining_dashboard.helper.http.requests.get",
            return_value=_streaming_resp([b"x" * 1024, b"x" * 1024]),
        ):
            resp = bounded_get("https://example.test/x", max_bytes=2048, proxies=_PROXIES)
        assert resp.content == b"x" * 2048

    def test_over_cap_raises_request_exception(self):
        # ResponseTooLarge subclasses RequestException, so every caller's existing
        # fail-silent handling (return None / keep last good) applies unchanged.
        with patch(
            "mining_dashboard.helper.http.requests.get",
            return_value=_streaming_resp([b"x" * 1024] * 3),
        ):
            with pytest.raises(requests.RequestException):
                bounded_get("https://example.test/x", max_bytes=2048, proxies=_PROXIES)

    def test_stops_reading_at_the_cap(self):
        # The over-cap chunk is the last one consumed — the rest of a multi-GB body is never read.
        chunks = iter([b"x" * 1024, b"x" * 1024, b"x" * 1024])
        with patch(
            "mining_dashboard.helper.http.requests.get",
            return_value=_streaming_resp(chunks),
        ):
            with pytest.raises(ResponseTooLarge):
                bounded_get("https://example.test/x", max_bytes=1024, proxies=_PROXIES)
        assert next(chunks, None) is not None  # at least one chunk was left unread

    def test_kwargs_pass_through(self):
        with patch(
            "mining_dashboard.helper.http.requests.get",
            return_value=_streaming_resp([b"ok"]),
        ) as g:
            bounded_get(
                "https://example.test/x",
                timeout=20,
                proxies={"https": "socks5h://tor:9050"},
                params={"a": "b"},
                headers={"User-Agent": "pithead-dashboard"},
            )
        kw = g.call_args.kwargs
        assert kw["timeout"] == 20
        assert kw["proxies"] == {"https": "socks5h://tor:9050"}
        assert kw["params"] == {"a": "b"}
        assert kw["headers"] == {"User-Agent": "pithead-dashboard"}

    def test_bad_encoding_degrades_not_crashes(self):
        resp_obj = _streaming_resp([b"\xff\xfe"], encoding=None)
        with patch("mining_dashboard.helper.http.requests.get", return_value=resp_obj):
            resp = bounded_get("https://example.test/x", proxies=_PROXIES)
        assert isinstance(resp.text, str)  # errors="replace", never a decode crash

    def test_raise_for_status_matches_requests_contract(self):
        # The Telegram long-poll calls raise_for_status(); an HTTP error must surface as a
        # RequestException so the caller's existing catch-and-backoff applies unchanged.
        BoundedResponse(200, b"", "utf-8").raise_for_status()  # 2xx: no raise
        with pytest.raises(requests.RequestException):
            BoundedResponse(502, b"", "utf-8").raise_for_status()


class TestBoundedDeadline:
    def _trickle(self, n, delay):
        for _ in range(n):
            time.sleep(delay)
            yield b"x"

    def test_a_trickling_body_past_the_deadline_times_out(self):
        resp = _streaming_resp([])
        resp.iter_content.return_value = self._trickle(100, 0.05)
        with patch("mining_dashboard.helper.http.requests.get", return_value=resp):
            started = time.monotonic()
            with pytest.raises(requests.Timeout):
                bounded_get("https://example.test/x", deadline=0.2, proxies=_PROXIES)
        assert time.monotonic() - started < 1

    def test_a_body_inside_the_deadline_is_returned(self):
        resp = _streaming_resp([b"ok"])
        with patch("mining_dashboard.helper.http.requests.get", return_value=resp):
            assert bounded_get("https://example.test/x", deadline=5, proxies=_PROXIES).content == (
                b"ok"
            )


class TestEgressGuard:
    def test_public_host_without_proxy_is_refused(self):
        with patch("mining_dashboard.helper.http.requests.get") as g:
            with pytest.raises(NoUsableProxy):
                bounded_get("https://api.github.com/repos/x/releases/latest")
        g.assert_not_called()

    def test_the_refusal_is_a_request_exception_subclass(self):
        assert issubclass(NoUsableProxy, requests.RequestException)

    def test_the_refusal_opens_no_socket(self):
        with patch("socket.socket") as sock:
            with pytest.raises(NoUsableProxy):
                bounded_get("https://api.github.com/x")
            with pytest.raises(NoUsableProxy):
                bounded_request("POST", "http://8.8.8.8:8080/json_rpc")
        sock.assert_not_called()

    def test_a_malformed_url_raises_a_request_exception(self):
        with patch("mining_dashboard.helper.http.requests.get") as g:
            with pytest.raises(NoUsableProxy):
                bounded_get("http://[::1")
        g.assert_not_called()

    def test_a_netloc_with_a_backslash_is_refused(self):
        with patch("mining_dashboard.helper.http.requests.get") as g:
            for url in ("http://evil.com\\@10.0.0.1/x", "http://10.0.0.1\\@evil.com/x"):
                with pytest.raises(NoUsableProxy):
                    bounded_get(url, proxies=_PROXIES)
        g.assert_not_called()

    def test_a_private_host_behind_userinfo_is_still_evaluated(self):
        with patch(
            "mining_dashboard.helper.http.requests.get", return_value=_streaming_resp([b"ok"])
        ):
            assert bounded_get("https://user:pass@127.0.0.1:8000/api/x").content == b"ok"
        with pytest.raises(NoUsableProxy):
            bounded_get("http://10.0.0.1@evil.com/x")

    def test_a_session_caller_to_a_public_host_is_refused(self):
        session = MagicMock()
        with pytest.raises(NoUsableProxy):
            bounded_request("GET", "https://example.test/1/summary", session=session)
        assert not session.get.called

    def test_empty_proxies_string_counts_as_no_proxy(self):
        with pytest.raises(NoUsableProxy):
            bounded_get("https://example.test/x", proxies="")

    def test_empty_scheme_entries_count_as_no_proxy(self):
        with pytest.raises(NoUsableProxy):
            bounded_get("https://example.test/x", proxies={"https": ""})
        with pytest.raises(NoUsableProxy):
            bounded_get("http://example.test/x", proxies={"http": ""})
        with pytest.raises(NoUsableProxy):
            bounded_get("https://example.test/x", proxies={"https": "   "})

    def test_the_proxy_is_checked_per_target_scheme(self):
        with pytest.raises(NoUsableProxy):
            bounded_get("https://example.test/x", proxies={"http": "socks5h://tor.test:9050"})
        with pytest.raises(NoUsableProxy):
            bounded_get("http://example.test/x", proxies={"https": "socks5h://tor.test:9050"})
        with patch(
            "mining_dashboard.helper.http.requests.get", return_value=_streaming_resp([b"ok"])
        ):
            got = bounded_get("https://example.test/x", proxies={"https": "socks5h://t:1"})
        assert got.content == b"ok"

    def test_a_string_proxy_covers_every_scheme(self):
        with patch(
            "mining_dashboard.helper.http.requests.get", return_value=_streaming_resp([b"ok"])
        ):
            assert bounded_get("https://example.test/x", proxies="socks5h://t:1").content == b"ok"

    def test_hostnames_are_never_private(self):
        for url in (
            "http://localhost:8080/x",
            "http://mybox.local/x",
            "http://1234/x",
            "https://example.test/x",
        ):
            with pytest.raises(NoUsableProxy):
                bounded_get(url)

    def test_private_ip_literals_are_allowed_direct(self):
        urls = [
            "http://127.0.0.1:3344/1/summary",
            "https://10.0.0.5/x",
            "http://172.16.9.9/x",
            "https://192.168.1.7/x",
            "http://169.254.10.1/x",
            "https://100.64.0.1/x",
            "https://100.127.255.255/x",
            "http://[::1]:8080/x",
            "https://[fd00::7]/x",
            "https://[fc00::1]/x",
            "https://[fe80::1]/x",
        ]
        with patch(
            "mining_dashboard.helper.http.requests.get",
            side_effect=lambda *args, **kwargs: _streaming_resp([b"ok"]),
        ) as g:
            for url in urls:
                assert bounded_get(url).content == b"ok"
        assert g.call_count == len(urls)

    def test_public_ip_literals_are_refused_without_a_proxy(self):
        for url in (
            "https://8.8.8.8/x",
            "https://100.128.0.1/x",
            "https://172.32.0.1/x",
            "https://[2001:4860:4860::8888]/x",
            "https://16842753/x",
            "HTTP://EXAMPLE.COM/x",
        ):
            with pytest.raises(NoUsableProxy):
                bounded_get(url)

    def test_an_unproxied_call_never_follows_redirects(self):
        with patch(
            "mining_dashboard.helper.http.requests.get", return_value=_streaming_resp([b"ok"])
        ) as g:
            bounded_get("http://10.0.0.1:18081/json_rpc")
            bounded_get("http://127.0.0.1/x", allow_redirects=True)
        for call in g.call_args_list:
            assert call.kwargs["allow_redirects"] is False

    def test_a_proxied_call_keeps_redirects_on_the_proxy(self):
        with patch(
            "mining_dashboard.helper.http.requests.get", return_value=_streaming_resp([b"ok"])
        ) as g:
            bounded_get("https://example.test/x", proxies=_PROXIES)
        assert "allow_redirects" not in g.call_args.kwargs


class _Stream:
    """An aiohttp ``StreamReader``: ``read(n)`` is a SHORT read, returning what is buffered rather
    than ``n`` bytes. Measured against a real aiohttp server while fixing #1347 — one ``read(1000)``
    of a 994-byte body came back with 100 bytes."""

    def __init__(self, raw, chunk=1024):
        self._raw, self._pos, self._chunk = raw, 0, chunk
        self.bytes_read = 0

    async def read(self, n=-1):
        end = len(self._raw) if n < 0 else min(len(self._raw), self._pos + min(n, self._chunk))
        chunk, self._pos = self._raw[self._pos : end], end
        self.bytes_read += len(chunk)
        return chunk


class TestBoundedRead:
    """The async twin (#1360). The aiohttp call sites differ in everything — session, params,
    timeout, whether they want bytes/text/JSON — except this one step, so the helper takes the
    stream rather than making the request."""

    async def test_a_body_up_to_the_cap_is_returned_whole(self):
        # The accept side matters most: a cap that refuses a legitimate body presents to the
        # operator as the far end being broken, which is worse than the exhaustion it prevents.
        assert await bounded_read(_Stream(b"x" * 2048), max_bytes=2048) == b"x" * 2048

    async def test_one_byte_past_the_cap_is_refused(self):
        with pytest.raises(ResponseTooLarge):
            await bounded_read(_Stream(b"x" * 2049), max_bytes=2048)

    async def test_it_raises_the_same_type_as_the_sync_twin(self):
        # Callers here fail silently on requests.RequestException; sharing the type means their
        # existing handling covers a refusal with no change.
        with pytest.raises(requests.RequestException):
            await bounded_read(_Stream(b"x" * 4), max_bytes=2)

    async def test_a_body_split_across_many_reads_is_still_read_whole(self):
        # The regression a single read(max_bytes) would cause, and the reason the fake above models
        # a short read at all: any link with latency delivers a body in pieces.
        stream = _Stream(b"y" * 8192, chunk=97)  # a deliberately unaligned chunk
        assert await bounded_read(stream, max_bytes=MAX_RESPONSE_BYTES) == b"y" * 8192

    async def test_an_oversized_body_delivered_in_pieces_is_still_refused(self):
        with pytest.raises(ResponseTooLarge):
            await bounded_read(_Stream(b"y" * 8192, chunk=97), max_bytes=4096)

    async def test_it_stops_reading_at_the_cap(self):
        # Refusing after buffering the whole body would prevent nothing at all.
        stream = _Stream(b"z" * (10 * 1024 * 1024), chunk=65536)
        with pytest.raises(ResponseTooLarge):
            await bounded_read(stream, max_bytes=4096)
        assert stream.bytes_read <= 4097

    async def test_a_trickled_body_does_not_cost_quadratic_time(self):
        """A cap that turns memory exhaustion into CPU exhaustion is not a fix.

        The read is SHORT, so the far end chooses how many reads a body takes: one byte per TCP
        segment makes ~n of them. Accumulating into immutable ``bytes`` re-copies the whole buffer
        each time, and this is asyncio — that time is the WHOLE event loop, not one coroutine.

        This is a timing assertion, which is the honest way to catch a complexity regression and is
        worth naming as such. The bound is sized off measurement rather than guessed: 512 KiB takes
        ~0.31s accumulating linearly and ~15s quadratically (extrapolated from 3.68s at 256 KiB,
        measured on this box under load). 4s therefore sits ~10x above the linear cost and ~4x below
        the quadratic one, so it takes a very badly loaded box to false-red and no plausible one to
        false-green."""

        class Trickle:
            """One byte per read — what aiohttp hands back when the sender writes one byte per
            segment, and the worst case the short read allows."""

            def __init__(self, n):
                self.left = n

            async def read(self, n=-1):
                if self.left <= 0:
                    return b""
                self.left -= 1
                return b"x"

        size = 512 * 1024
        started = time.perf_counter()
        body = await bounded_read(Trickle(size), max_bytes=4 * 1024 * 1024)
        elapsed = time.perf_counter() - started
        assert len(body) == size  # the trickle is read whole, not just quickly
        assert elapsed < 4.0, (
            f"{elapsed:.1f}s for {size} one-byte reads — accumulation went quadratic"
        )

    async def test_an_empty_body_is_not_an_error(self):
        assert await bounded_read(_Stream(b"")) == b""

    async def test_the_refusal_names_what_was_being_read(self):
        # These log at the caller; a message saying only "too large" would not say which container
        # or which endpoint, on a box polling several every cycle.
        with pytest.raises(ResponseTooLarge, match="monerod logs"):
            await bounded_read(_Stream(b"x" * 4), max_bytes=2, what="monerod logs")


class TestBoundedRequest:
    def test_it_uses_a_caller_s_own_session(self):
        """The xmrig-proxy client mounts a deliberate ``Retry`` adapter and polls twice a cycle;
        bounding its reads must not silently drop that by falling back to module-level requests."""
        session = MagicMock()
        session.get.return_value = _streaming_resp([b"{}"])
        resp = bounded_request("GET", "http://127.0.0.1:3344/1/summary", session=session)
        assert resp.json() == {}
        assert session.get.called
        assert session.get.call_args.kwargs["stream"] is True

    def test_it_dispatches_on_the_method(self):
        session = MagicMock()
        session.put.return_value = _streaming_resp([b'{"ok": true}'])
        assert bounded_request(
            "PUT", "http://127.0.0.1:3344/1/config", session=session, json={"a": 1}
        ).json() == {"ok": True}
        assert session.put.call_args.kwargs["json"] == {"a": 1}
        assert not session.get.called

    def test_no_session_falls_back_to_module_level_requests(self):
        with patch(
            "mining_dashboard.helper.http.requests.post", return_value=_streaming_resp([b"{}"])
        ) as post:
            bounded_request("POST", "http://127.0.0.1:18081/json_rpc", json={"m": "x"})
        assert post.call_args.kwargs["json"] == {"m": "x"}

    def test_the_cap_applies_to_any_method(self):
        session = MagicMock()
        session.put.return_value = _streaming_resp([b"x" * 1024] * 3)
        with pytest.raises(ResponseTooLarge):
            bounded_request(
                "PUT", "http://127.0.0.1:3344/1/config", max_bytes=2048, session=session
            )

    def test_bounded_get_still_delegates_with_its_660_signature(self):
        with patch(
            "mining_dashboard.helper.http.requests.get", return_value=_streaming_resp([b"{}"])
        ) as g:
            bounded_get("https://example.test/x", timeout=7, params={"a": "b"}, proxies=_PROXIES)
        assert g.call_args.kwargs["timeout"] == 7
        assert g.call_args.kwargs["params"] == {"a": "b"}
        assert g.call_args.kwargs["stream"] is True


class TestWiringDriftGuard:
    def test_external_clients_route_through_bounded_get(self):
        """Every external fetch module goes via bounded_get — any direct requests.<verb>( is drift."""
        pkg = Path(__file__).resolve().parents[2] / "mining_dashboard"
        external = [
            pkg / "service" / "health" / "update_checker.py",
            pkg / "service" / "xvb" / "price_feed.py",
            pkg / "client" / "xvb_client.py",
            pkg / "service" / "health" / "tor_heal.py",
            pkg / "service" / "notify" / "healthchecks_child.py",
        ]
        direct_call = re.compile(r"requests\.(get|post|put|delete|head|request)\(")
        for mod in external:
            src = mod.read_text()
            hit = direct_call.search(src)
            assert hit is None, (
                f"{mod.name}: unbounded {hit.group() if hit else ''} slipped back in"
            )
            assert "bounded_get(" in src, f"{mod.name}: no bounded_get call found"

    def test_telegram_get_updates_routes_through_bounded_get(self):
        """The getUpdates long-poll is bounded. The module's requests.post( sends (sendMessage,
        answerCallbackQuery) keep their own contract — tiny echo bodies of caller-authored
        payloads — so only GETs are drift here."""
        pkg = Path(__file__).resolve().parents[2] / "mining_dashboard"
        src = (pkg / "service" / "notify" / "telegram_commands.py").read_text()
        hit = re.search(r"requests\.(get|head|request)\(", src)
        assert hit is None, f"telegram_commands.py: unbounded {hit.group() if hit else ''}"
        assert "bounded_get(" in src

    def test_the_1360_internal_clients_route_through_the_bounded_helpers(self):
        """#660 exempted the clients it judged *internal*; that exemption did not survive contact
        (#1347), and #1360 brought the rest of the set behind the same helpers. This is a text
        check and proves only the text — the behavioural half is one refusal test per site, in each
        site's own test module."""
        pkg = Path(__file__).resolve().parents[2] / "mining_dashboard"
        sync_sites = {
            pkg / "client" / "monero" / "monero_client.py": r"requests\.(get|post|put|request)\(",
            pkg
            / "client"
            / "monero"
            / "monero_wallet_client.py": r"requests\.(get|post|put|request)\(",
            # This one calls through its own Session, so the drift to watch for is self.session.<verb>(
            pkg / "client" / "xmrig_proxy_client.py": r"self\.session\.(get|post|put)\(",
        }
        for mod, pattern in sync_sites.items():
            src = mod.read_text()
            hit = re.search(pattern, src)
            assert hit is None, (
                f"{mod.name}: unbounded {hit.group() if hit else ''} slipped back in"
            )
            assert "bounded_get(" in src or "bounded_request(" in src, f"{mod.name}: not bounded"

        async_sites = {
            pkg / "collector" / "logs.py": r"await response\.(read|text|json)\(",
            pkg / "collector" / "containers.py": r"await response\.(read|text|json)\(",
            pkg / "client" / "docker" / "docker_control.py": r"await resp\.(read|text|json)\(",
            # #1347's own site. It is where this algorithm was worked out, and it kept a second
            # copy until #1360 folded it back in -- the two had already diverged (only the helper
            # got the bytearray fix). The pattern below is the hand-rolled loop coming back.
            pkg / "client" / "xmrig_client.py": r"await response\.content\.read\(",
        }
        for mod, pattern in async_sites.items():
            src = mod.read_text()
            hit = re.search(pattern, src)
            assert hit is None, (
                f"{mod.name}: unbounded {hit.group() if hit else ''} slipped back in"
            )
            assert "bounded_read(" in src, f"{mod.name}: no bounded_read call found"
