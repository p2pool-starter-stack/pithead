"""No network: exercise the exact helper sent to the dashboard container."""

import importlib.util
import io
import json
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

SPEC = importlib.util.spec_from_file_location(
    "rotate_probe", Path(__file__).resolve().parents[1] / "rotate-auth-probe.py"
)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class StratumProbeTest(unittest.TestCase):
    def probe(self, response):
        connection = MagicMock()
        connection.__enter__.return_value = connection
        connection.makefile.return_value = io.BytesIO(response)
        with patch.object(PROBE.socket, "create_connection", return_value=connection):
            verdict = PROBE.login("private-test-password", "unused")
        sent = json.loads(connection.sendall.call_args.args[0])
        self.assertEqual(sent["params"]["pass"], "private-test-password")
        return verdict

    def test_new_password_requires_a_real_mining_job(self):
        reply = {
            "id": 1,
            "result": {"status": "OK", "job": {"blob": "b", "job_id": "j", "target": "t"}},
        }
        self.assertEqual(self.probe(json.dumps(reply).encode() + b"\n"), "accepted")
        reply["result"].pop("job")
        self.assertEqual(self.probe(json.dumps(reply).encode() + b"\n"), "failed")

    def test_old_password_requires_an_explicit_password_refusal(self):
        self.assertEqual(
            self.probe(b'{"id":1,"error":{"message":"Permission denied"}}\n'), "refused"
        )
        self.assertEqual(self.probe(b'{"id":1,"error":{"message":"Pool offline"}}\n'), "failed")

    def test_bad_or_unbounded_responses_are_not_authentication_evidence(self):
        for response in (b"not json\n", b"[]\n", b"{}", b"x" * 65537):
            with self.subTest(response=response[:10]):
                self.assertEqual(self.probe(response), "failed")

    def test_network_error_is_neither_acceptance_nor_refusal(self):
        with patch.object(PROBE.socket, "create_connection", side_effect=TimeoutError):
            self.assertEqual(PROBE.login("private-test-password", "unused"), "failed")

    def test_http_probe_uses_explicit_status_and_bounded_private_client(self):
        client = MagicMock(base_url="unused")
        constructor = MagicMock(return_value=client)
        request = MagicMock()
        modules = {
            "mining_dashboard.client.xmrig_proxy_client": SimpleNamespace(
                XMRigProxyClient=constructor, bounded_request=request
            ),
            "mining_dashboard.config.config": SimpleNamespace(
                PROXY_HOST="unused", PROXY_API_PORT=1
            ),
        }
        with patch.dict(sys.modules, modules):
            for status in (200, 401, 500):
                request.return_value.status_code = status
                self.assertEqual(PROBE.proxy_status("private-test-token"), status)
            constructor.assert_called_with("unused", 1, "private-test-token")
            request.assert_called_with("GET", "unused/1/config", timeout=5, session=client.session)
            request.side_effect = TimeoutError
            with self.assertRaises(TimeoutError):
                PROBE.proxy_status("private-test-token")


if __name__ == "__main__":
    unittest.main()
