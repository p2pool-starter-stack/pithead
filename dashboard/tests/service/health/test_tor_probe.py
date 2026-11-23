"""Tor SOCKS circuit isolation against a fake endpoint and bounded HTTP probes."""

import importlib
import socket
import threading
from unittest.mock import patch

import requests

import mining_dashboard.service.health.tor_heal as tor_heal
from mining_dashboard.service.health.tor_heal import TorEgressHealer


class TestProbe:
    def test_fake_socks_endpoint_fails_one_circuit_then_succeeds_on_another(self):
        usernames = []
        errors = []

        def exact(conn, size):
            data = b""
            while len(data) < size:
                part = conn.recv(size - len(data))
                if not part:
                    raise EOFError
                data += part
            return data

        def serve(listener):
            try:
                for attempt in range(2):
                    conn, _ = listener.accept()
                    with conn:
                        conn.settimeout(5)
                        _, count = exact(conn, 2)
                        exact(conn, count)
                        conn.sendall(b"\x05\x02")
                        _, length = exact(conn, 2)
                        usernames.append(exact(conn, length).decode())
                        password_length = exact(conn, 1)[0]
                        assert exact(conn, password_length) == b"isolate"
                        conn.sendall(b"\x01\x00")
                        _, _, _, address_type = exact(conn, 4)
                        if address_type == 3:
                            exact(conn, exact(conn, 1)[0])
                        else:
                            exact(conn, 4 if address_type == 1 else 16)
                        exact(conn, 2)
                        conn.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
                        if attempt:
                            request = b""
                            while b"\r\n\r\n" not in request:
                                request += exact(conn, 1)
                            conn.sendall(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
            except Exception as exc:
                errors.append(exc)

        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(2)
            listener.settimeout(5)
            thread = threading.Thread(target=serve, args=(listener,))
            thread.start()
            with (
                patch.object(
                    tor_heal, "TOR_SOCKS_PROXY", f"socks5h://127.0.0.1:{listener.getsockname()[1]}"
                ),
                patch.object(tor_heal, "PROBE_URL", "http://one.test/"),
                patch.object(tor_heal, "SECOND_PROBE_URL", "http://two.test/"),
            ):
                ok, _ = TorEgressHealer._probe_egress()
            thread.join(timeout=5)
        assert not thread.is_alive()
        assert not errors
        assert ok
        assert len(usernames) == 2 and usernames[0] != usernames[1]

    def test_any_http_response_counts_as_egress(self):
        with patch("mining_dashboard.service.health.tor_heal.bounded_get") as get:
            ok, evidence = TorEgressHealer._probe_egress()
            assert ok is True
            assert "answered" in evidence
            proxy = get.call_args.kwargs["proxies"]["https"]
            assert proxy.startswith("socks5h://")
            assert proxy == get.call_args.kwargs["proxies"]["http"]
            assert evidence.split("circuit ")[1][:8] in proxy

    def test_network_failure_is_broken_egress(self):
        with patch(
            "mining_dashboard.service.health.tor_heal.bounded_get",
            side_effect=requests.ConnectionError("circuit timeout"),
        ):
            ok, evidence = TorEgressHealer._probe_egress()
        assert ok is False
        assert "isolate@" not in evidence and "circuit timeout" not in evidence

    def test_one_bad_circuit_does_not_count_as_failed_egress(self):
        with patch(
            "mining_dashboard.service.health.tor_heal.bounded_get",
            side_effect=[requests.ConnectionError("dead exit"), object()],
        ) as get:
            ok, evidence = TorEgressHealer._probe_egress()
        assert ok
        assert len(get.call_args_list) == 2
        assert (
            get.call_args_list[0].kwargs["proxies"]["https"]
            != get.call_args_list[1].kwargs["proxies"]["https"]
        )
        assert ":isolate@" in get.call_args_list[0].kwargs["proxies"]["https"]
        assert "cloudflare" in evidence


def test_schemeless_proxy_is_a_failed_probe_not_an_exception(monkeypatch):
    monkeypatch.setattr("mining_dashboard.service.health.tor_heal.TOR_SOCKS_PROXY", "tor:9050")
    ok, evidence = TorEgressHealer._probe_egress()
    assert ok is False and "ValueError" in evidence


class TestProbeTargets:
    def test_defaults_are_the_public_https_targets(self, monkeypatch):
        monkeypatch.delenv("TOR_HEAL_PROBE_URL", raising=False)
        monkeypatch.delenv("TOR_HEAL_SECOND_PROBE_URL", raising=False)
        try:
            module = importlib.reload(tor_heal)
            assert module.PROBE_URL == "https://www.google.com/generate_204"
            assert module.SECOND_PROBE_URL == "https://www.cloudflare.com/cdn-cgi/trace"
        finally:
            importlib.reload(tor_heal)

    def test_environment_overrides_both_targets_and_empty_keeps_defaults(self, monkeypatch):
        monkeypatch.setenv("TOR_HEAL_PROBE_URL", "http://10.0.0.9:8080/a")
        monkeypatch.setenv("TOR_HEAL_SECOND_PROBE_URL", "")
        try:
            module = importlib.reload(tor_heal)
            assert module.PROBE_URL == "http://10.0.0.9:8080/a"
            assert module.SECOND_PROBE_URL == "https://www.cloudflare.com/cdn-cgi/trace"
        finally:
            monkeypatch.delenv("TOR_HEAL_PROBE_URL")
            monkeypatch.delenv("TOR_HEAL_SECOND_PROBE_URL")
            importlib.reload(tor_heal)
