import importlib.util
import io
import itertools
import json
import socket
import sys
import threading
import unittest
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

SPEC = importlib.util.spec_from_file_location(
    "rotate_probe", Path(__file__).resolve().parents[1] / "rotate-auth-probe.py"
)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class StratumProbeTest(unittest.TestCase):
    def probe(self, response, require_upstream=False):
        connection = MagicMock()
        self.connection = connection
        connection.__enter__.return_value = connection
        connection.makefile.return_value = io.BytesIO(response)
        with patch.object(PROBE.socket, "create_connection", return_value=connection):
            verdict = PROBE.login("private-test-password", "unused", require_upstream)
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

    def test_route_checks_upstream_while_authenticated_connection_is_open(self):
        response = (
            b'{"id":1,"result":{"status":"OK","job":{"blob":"b","job_id":"j","target":"t"}}}\n'
        )

        def active():
            self.connection.__exit__.assert_not_called()
            return True

        with patch.object(PROBE, "proxy_upstream_active", side_effect=active) as check:
            self.assertEqual(self.probe(response, require_upstream=True), "accepted")
            check.assert_called_once()
            self.connection.__exit__.assert_called_once()

    def test_route_requires_both_authentication_and_an_observed_upstream(self):
        response = (
            b'{"id":1,"result":{"status":"OK","job":{"blob":"b","job_id":"j","target":"t"}}}\n'
        )
        with patch.object(PROBE, "proxy_upstream_active", return_value=False) as check:
            self.assertEqual(self.probe(response, require_upstream=True), "failed")
            check.reset_mock()
            self.assertEqual(self.probe(b'{"id":1,"error":{}}\n', require_upstream=True), "failed")
            check.assert_not_called()
        with patch.object(PROBE, "proxy_upstream_active", side_effect=TimeoutError):
            self.assertEqual(self.probe(response, require_upstream=True), "failed")

    def test_upstream_summary_requires_a_positive_integer_not_a_missing_or_malformed_value(self):
        client = MagicMock()
        constructor = MagicMock(return_value=client)
        sample = "private-test-token"
        modules = {
            "mining_dashboard.client.xmrig_proxy_client": SimpleNamespace(
                XMRigProxyClient=constructor
            ),
            "mining_dashboard.config.config": SimpleNamespace(
                PROXY_HOST="unused", PROXY_API_PORT=1, PROXY_AUTH_TOKEN=sample
            ),
        }
        with patch.dict(sys.modules, modules):
            for summary in (None, [], {}, {"upstreams": []}):
                client.get_summary.return_value = summary
                self.assertFalse(PROBE.proxy_upstream_active())
            for value in (None, 0, -1, True, "1", 1):
                client.get_summary.return_value = {"upstreams": {"active": value}}
                self.assertEqual(PROBE.proxy_upstream_active(), type(value) is int and value > 0)
            constructor.assert_called_with("unused", 1, "private-test-token")

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
            for status in (200, 401, 403, 500):
                request.return_value.status_code = status
                self.assertEqual(PROBE.proxy_status("private-test-token"), status)
            constructor.assert_called_with("unused", 1, "private-test-token")
            request.assert_called_with("GET", "unused/1/config", timeout=5, session=client.session)
            request.side_effect = TimeoutError
            with self.assertRaises(TimeoutError):
                PROBE.proxy_status("private-test-token")


class StratumControlsTest(unittest.TestCase):
    @contextmanager
    def server(self, guard=True):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        seen = []

        def serve():
            with listener:
                connection, _ = listener.accept()
                with connection, connection.makefile("rb") as stream:
                    request = json.loads(stream.readline())
                    seen.append(request)
                    if guard and request["params"].get("pass") != "fixture-secret":
                        reply = {"id": 1, "error": {"message": "Permission denied"}}
                    else:
                        reply = {
                            "id": 1,
                            "result": {
                                "status": "OK",
                                "job": {
                                    "blob": "b",
                                    "job_id": "j",
                                    "target": "t",
                                },
                            },
                        }
                    connection.sendall(json.dumps(reply).encode() + b"\n")

        thread = threading.Thread(target=serve)
        thread.start()
        try:
            yield listener.getsockname()[1], seen
        finally:
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive())

    def test_refusal_control_detects_removed_authentication_guard(self):
        for password in ("wrong-secret", None):
            for guard in (True, False):
                with (
                    self.subTest(password=password, guard=guard),
                    self.server(guard) as (port, seen),
                ):
                    with patch.object(PROBE, "worker_sample", return_value=(0, 0)):
                        if guard:
                            PROBE.raw_control(password, port, "unique-fixture", None, "refused", 0)
                        else:
                            with self.assertRaises(ValueError):
                                PROBE.raw_control(
                                    password, port, "unique-fixture", None, "refused", 0
                                )
                    self.assertEqual(seen[0]["params"]["rigid"], "unique-fixture")
                    if password is None:
                        self.assertNotIn("pass", seen[0]["params"])

    def test_counter_requires_the_real_unique_numeric_row(self):
        for rows in (
            [],
            [["name", "ip", 0]],
            [["name", "ip", 0, "0"]],
            [["name", "ip", False, 0]],
            [["name", "ip", 0, -1]],
            [["name", "ip", 0, 0], ["name", "ip", 0, 0]],
        ):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                PROBE.worker_counter({"workers": rows}, "name")
        self.assertEqual(PROBE.worker_counter({"workers": [["name", "ip", 0, 0]]}, "name"), (0, 0))

    def test_negative_control_polls_for_the_full_window(self):
        with (
            patch.object(PROBE.time, "monotonic", side_effect=[0, 1, 60, 120]),
            patch.object(PROBE.time, "sleep") as pause,
            patch.object(PROBE, "worker_sample", return_value=(0, 0)) as sample,
            patch.object(PROBE, "login", return_value="refused") as login,
        ):
            PROBE.raw_control("wrong", 3333, "name", None, "refused", 120)
            self.assertEqual(login.call_count, 3)
            self.assertEqual(sample.call_count, 6)
            self.assertEqual(pause.call_count, 2)

    def test_negative_control_rejects_transient_activity_and_shares(self):
        for values in (((1, 0),), ((0, 1),), ((0, 0), (1, 0)), ((0, 0), (0, 1))):
            with (
                self.subTest(values=values),
                patch.object(PROBE, "worker_sample", side_effect=values),
                patch.object(PROBE, "login", return_value="refused"),
                self.assertRaises(ValueError),
            ):
                PROBE.raw_control("wrong", 3333, "name", None, "refused", 120)

    def test_wrong_pin_sends_no_login_even_when_tls_handshake_succeeds(self):
        transport = MagicMock()
        transport.__enter__.return_value = transport
        tls = MagicMock()
        tls.__enter__.return_value = tls
        tls.getpeercert.return_value = b"certificate"
        context = MagicMock()
        context.wrap_socket.return_value = tls
        with (
            patch.object(PROBE.socket, "create_connection", return_value=transport),
            patch.object(PROBE.ssl, "SSLContext", return_value=context),
        ):
            self.assertEqual(PROBE.login("secret", "host", pin="0" * 64), "pin-refused")
            tls.sendall.assert_not_called()
            tls.__exit__.assert_called_once()
            pin = PROBE.hashlib.sha256(b"certificate").hexdigest()
            tls.makefile.return_value = io.BytesIO(
                b'{"id":1,"result":{"status":"OK","job":{"blob":"b","job_id":"j","target":"t"}}}\n'
            )
            self.assertEqual(PROBE.login("secret", "host", pin=pin), "accepted")
            tls.sendall.assert_called_once()

    def test_refusal_with_a_simultaneous_job_is_not_a_refusal(self):
        case = StratumProbeTest()
        self.assertEqual(
            case.probe(b'{"id":1,"error":{"message":"Permission denied"},"result":{"job":{}}}\n'),
            "failed",
        )


class StratumMinerTest(unittest.TestCase):
    def run_miner(self, expected, text, samples, password=None, pin=None, active=True):
        process = MagicMock()
        process.poll.return_value = None if active else 1
        self.config = None
        self.config_path = None

        def launch(argv, stdout, stderr):
            self.config_path = Path(argv[2])
            self.config = json.loads(self.config_path.read_text())
            self.assertEqual(self.config_path.stat().st_mode & 0o777, 0o600)
            stdout.write(text)
            stdout.flush()
            return process

        with (
            patch.object(PROBE.subprocess, "Popen", side_effect=launch),
            patch.object(
                PROBE,
                "worker_sample",
                side_effect=itertools.chain(samples, itertools.repeat(samples[-1])),
            ),
            patch.object(PROBE.time, "monotonic", side_effect=[0, 1, 120, 121]),
            patch.object(PROBE.time, "sleep"),
        ):
            try:
                PROBE.xmrig_control("shipped-xmrig", password, 3333, "fixture", pin, expected, 120)
            finally:
                process.terminate.assert_called_once()
                process.wait.assert_called_once()
                self.assertFalse(self.config_path.exists())
        return self.config

    def test_shipped_miner_refuses_wrong_and_unconfigured_password(self):
        for password in ("wrong", None):
            config = self.run_miner(
                "refused", 'error: "Permission denied", code: -1', [(0, 0), (0, 0)], password
            )
            self.assertEqual("pass" in config["pools"][0], password is not None)
            self.assertEqual(config["pools"][0]["rig-id"], "fixture")
            self.assertEqual(config["pools"][0]["user"], "fixture+100")

    def test_bad_pin_requires_explicit_fingerprint_error_and_no_job(self):
        config = self.run_miner(
            "pin-refused",
            "Failed to verify server certificate fingerprint",
            [(0, 0), (0, 0)],
            pin="0" * 64,
        )
        self.assertTrue(config["pools"][0]["tls"])
        self.assertEqual(config["pools"][0]["tls-fingerprint"], "0" * 64)
        for text in ("connection refused", 'new job from pool; error: "Permission denied"'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.run_miner("refused", text, [(0, 0), (0, 0)])

    def test_positive_requires_a_new_proxy_accepted_share(self):
        self.run_miner("accepted", "new job from pool", [(0, 7), (1, 7), (1, 8)])
        with self.assertRaises(ValueError):
            self.run_miner("accepted", "new job from pool", [(0, 7), (1, 7)])

    def test_dead_miner_fails_and_is_reaped(self):
        with self.assertRaises(ValueError):
            self.run_miner("refused", 'error: "Permission denied"', [(0, 0)], active=False)


class StratumSuiteTest(unittest.TestCase):
    def test_real_suite_drives_all_controls_from_the_connection_card(self):
        card = {
            "password": "fixture-secret",
            "tls": True,
            "fingerprint": "a" * 64,
            "url": "stratum+ssl://fixture:3344",
        }
        response = MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps(card).encode()
        for binary in (None, "shipped-xmrig"):
            with (
                self.subTest(binary=binary),
                patch.object(PROBE, "build_opener") as opener,
                patch.object(PROBE, "login", return_value="accepted") as login,
                patch.object(PROBE, "wait_counter"),
                patch.object(PROBE, "worker_sample", return_value=(0, 0)),
                patch.object(PROBE, "raw_control") as raw,
                patch.object(PROBE, "xmrig_control") as miner,
                patch("builtins.print"),
            ):
                opener.return_value.open.return_value = response
                PROBE.stratum_controls(binary)
                if binary:
                    self.assertEqual(miner.call_count, 5)
                    self.assertEqual(raw.call_count, 1)
                    self.assertIsNone(raw.call_args.args[0])
                    self.assertEqual(miner.call_args_list[3].args[4], "a" * 64)
                    self.assertIsNone(miner.call_args_list[4].args[4])
                else:
                    self.assertEqual(raw.call_count, 3)
                    self.assertEqual(login.call_count, 3)
                    self.assertEqual(login.call_args_list[1].kwargs["pin"], "a" * 64)
                    self.assertIsNone(login.call_args_list[2].kwargs["pin"])
                self.assertEqual(login.call_args_list[0].kwargs["port"], 3344)
                self.assertNotEqual(raw.call_args_list[0].args[2], "")


if __name__ == "__main__":
    unittest.main()
