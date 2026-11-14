from unittest.mock import patch

import requests

import mining_dashboard.service.notify.healthchecks as hc_mod
from mining_dashboard.service.notify.healthchecks import HealthchecksClient


class TestTorSocksClassification:
    URL = "https://hc-ping.com/secret-ping-token"

    def _client(self, recorder, **overrides):
        return HealthchecksClient(
            ping_url=self.URL, interval_seconds=60, record_failure=recorder, **overrides
        )

    def _recorder(self):
        rows = []
        return rows, lambda ts, reason, detail: rows.append((ts, reason, detail))

    def test_a_timeout_or_connect_failure_through_the_tor_proxy_is_tor_socks(self):
        rows, rec = self._recorder()
        c = self._client(rec, tor_proxy="socks5h://tor:9050")
        errs = [
            requests.exceptions.ConnectTimeout(f"timed out against {self.URL}"),
            requests.exceptions.ConnectionError(f"SOCKS5 error against {self.URL}"),
        ]
        for err in errs:
            with patch.object(hc_mod, "bounded_get", side_effect=err):
                assert c.ping() is False
        assert [r[1] for r in rows] == ["tor_socks", "tor_socks"]

    def test_real_socks5_error_reply_and_hung_handshake_are_tor_socks(self):
        import socket
        import threading

        def serve(mode, ready, port_box):
            srv = socket.socket()
            srv.bind(("127.0.0.1", 0))
            srv.listen(1)
            port_box.append(srv.getsockname()[1])
            ready.set()
            conn, _ = srv.accept()
            conn.recv(3)
            if mode == "reply":
                conn.sendall(b"\x05\x00")
                conn.recv(512)
                conn.sendall(b"\x05\x04\x00\x01\x00\x00\x00\x00\x00\x00")
            else:
                threading.Event().wait(2)
            conn.close()
            srv.close()

        for mode in ("reply", "hang"):
            rows, rec = self._recorder()
            ready, port_box = threading.Event(), []
            t = threading.Thread(target=serve, args=(mode, ready, port_box), daemon=True)
            t.start()
            ready.wait(5)
            c = self._client(rec, tor_proxy=f"socks5h://127.0.0.1:{port_box[0]}")
            with patch.object(hc_mod, "_PING_TIMEOUT_SEC", 0.5):
                assert c.ping() is False
            t.join(5)
            assert rows[0][1] == "tor_socks", (mode, rows)
