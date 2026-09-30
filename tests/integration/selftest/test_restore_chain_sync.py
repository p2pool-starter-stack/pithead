"""Exercise daemon restoration verdicts without Docker, network access or credentials."""

import contextlib
import hashlib
import importlib.util
import io
import json
import socket
import subprocess
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

SOURCE = Path(__file__).resolve().parents[1] / "lib" / "restore-chain-sync.py"
spec = importlib.util.spec_from_file_location("restore_chain_sync", SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DaemonProof(unittest.TestCase):
    def setUp(self):
        self.env = Mock(spec=Path)
        self.env.read_text.return_value = (
            "MONERO_RPC_URL=http://fixture.invalid:18081\n"
            "MONERO_NODE_USERNAME=fixture-user\nMONERO_NODE_PASSWORD=changeme\n"
        )

    def run_probe(
        self, monero=None, tari=None, error=None, credentials=("fixture-user", "changeme")
    ):
        if monero is None:
            monero = {"status": "OK", "synchronized": True}
        if tari is None:
            tari = {"initial_sync_achieved": True}
        with (
            patch.object(module, "monero_info", return_value=monero) as request,
            patch.object(module.shutil, "which", return_value="/fixture/docker"),
            patch.object(module.subprocess, "run") as run,
        ):
            run.side_effect = [error or types.SimpleNamespace(stdout=json.dumps(tari))]
            result = module.probe(self.env)
            request.assert_called_once_with("http://fixture.invalid:18081", *credentials)
            if result:
                run.assert_called_once_with(
                    ["/fixture/docker", "exec", "dashboard", "python3", "-c", module.TARI_PROBE],
                    capture_output=True,
                    text=True,
                    timeout=12,
                    check=True,
                )
            return result

    def test_fixed_failure_stage_distinguishes_daemon_predicates(self):
        self.assertFalse(self.run_probe(monero={"status": "OK", "synchronized": False}))
        self.assertEqual(module.STAGE, "monero-sync")
        self.assertFalse(self.run_probe(tari={"initial_sync_achieved": False}))
        self.assertEqual(module.STAGE, "tari-sync")
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_probe(error=subprocess.TimeoutExpired("private-endpoint", 12))
        self.assertEqual(module.STAGE, "tari-command")

    def test_independent_authenticated_sync(self):
        self.assertTrue(self.run_probe())

    def test_rendered_quoted_credentials_are_decoded_without_evaluation(self):
        password = 'space " quote \\ dollar $$ and $(exit 1)'  # noqa: S105 -- synthetic parser fixture
        self.env.read_text.return_value = (
            "MONERO_RPC_URL=http://fixture.invalid:18081\nMONERO_NODE_USERNAME=fixture-user\n"
            + "MONERO_NODE_PASSWORD="
            + json.dumps(password.replace("$", "$$"))
            + "\n"
        )
        self.assertTrue(self.run_probe(credentials=("fixture-user", password)))

    def test_monero_availability_is_insufficient(self):
        for body in ({"status": "OK"}, {"status": "OK", "synchronized": False}):
            with self.subTest(body=body):
                self.assertFalse(self.run_probe(monero=body))

    def test_monero_sync_must_be_boolean_and_status_ok(self):
        for body in (
            {"status": "BUSY", "synchronized": True},
            {"status": "OK", "synchronized": "true"},
            {"status": "OK", "synchronized": 1},
        ):
            with self.subTest(body=body):
                self.assertFalse(self.run_probe(monero=body))

    def test_tari_sync_must_be_present_and_true(self):
        for body in ({}, {"initial_sync_achieved": False}, {"initial_sync_achieved": "true"}):
            with self.subTest(body=body):
                self.assertFalse(self.run_probe(tari=body))

    def test_missing_credentials_or_endpoint_refuses_before_rpc(self):
        for key in ("MONERO_NODE_USERNAME", "MONERO_NODE_PASSWORD", "MONERO_RPC_URL"):
            with (
                self.subTest(key=key),
                patch.object(module.subprocess, "run") as request,
            ):
                before = self.env.read_text()
                self.env.read_text.return_value = "\n".join(
                    line for line in before.splitlines() if not line.startswith(key + "=")
                )
                self.assertFalse(module.probe(self.env))
                request.assert_not_called()
                self.assertEqual(module.STAGE, "environment")
                self.env.read_text.return_value = before

    def test_monero_transport_refuses_before_tari(self):
        with (
            patch.object(module, "monero_info", side_effect=TimeoutError("private-endpoint")),
            patch.object(module.subprocess, "run") as run,
            self.assertRaises(TimeoutError),
        ):
            module.probe(self.env)
        run.assert_not_called()
        self.assertEqual(module.STAGE, "monero-rpc")

    def test_failed_or_timed_out_tari_cannot_pass(self):
        for error in (
            subprocess.TimeoutExpired("probe", 12),
            subprocess.CalledProcessError(1, "probe"),
        ):
            with self.subTest(error=error), self.assertRaises(type(error)):
                self.run_probe(error=error)

    def test_entrypoint_refuses_errors_without_printing_private_detail(self):
        code = SOURCE.read_text()
        out = io.StringIO()
        with (
            patch.object(Path, "read_text", return_value=self.env.read_text()),
            patch.object(
                socket,
                "create_connection",
                side_effect=ValueError("private-endpoint fixture-password"),
            ) as connect,
            contextlib.redirect_stdout(out),
            self.assertRaises(SystemExit) as raised,
        ):
            exec(compile(code, str(SOURCE), "exec"), {"__name__": "__main__"})  # noqa: S102 -- checked-in entrypoint
        connect.assert_called_once()
        self.assertEqual(raised.exception.code, 1)
        self.assertEqual(out.getvalue(), "independent daemon sync not proved: monero-rpc\n")

    def test_direct_tari_probe_checks_the_daemon_field(self):
        for synced in (False, True):
            with self.subTest(synced=synced):
                channel = Mock()
                grpc = types.SimpleNamespace(
                    insecure_channel=Mock(return_value=contextlib.nullcontext(channel))
                )
                stub = Mock()
                stub.GetTipInfo.return_value = types.SimpleNamespace(initial_sync_achieved=synced)
                generated = types.SimpleNamespace(
                    base_node_pb2_grpc=types.SimpleNamespace(BaseNodeStub=Mock(return_value=stub))
                )
                empty = Mock()
                modules = {
                    "grpc": grpc,
                    "google.protobuf": types.SimpleNamespace(
                        empty_pb2=types.SimpleNamespace(Empty=empty)
                    ),
                    "mining_dashboard.client.tari.generated": generated,
                }
                out = io.StringIO()
                with (
                    patch.dict("sys.modules", modules),
                    patch.dict("os.environ", {"TARI_GRPC_ADDRESS": "fixture.invalid:18142"}),
                    contextlib.redirect_stdout(out),
                ):
                    exec(module.TARI_PROBE, {})  # noqa: S102 -- checked-in probe under fake gRPC modules
                self.assertIs(json.loads(out.getvalue())["initial_sync_achieved"], synced)
                grpc.insecure_channel.assert_called_once_with("fixture.invalid:18142")
                generated.base_node_pb2_grpc.BaseNodeStub.assert_called_once_with(channel)
                stub.GetTipInfo.assert_called_once_with(empty.return_value, timeout=8)


class DigestExchange(unittest.TestCase):
    """Real HTTPConnection/HTTPResponse framing over in-memory sockets."""

    def exchange(
        self,
        first=401,
        second=200,
        close=False,
        body=None,
        challenge=None,
        password="changeme",  # noqa: S107 -- synthetic protocol fixture
        url="http://fixture.invalid:18081",
    ):
        sockets = []
        requests = []
        challenges = challenge or (
            'Digest realm="monero-rpc", nonce="fixture-nonce", algorithm=MD5, qop="auth"\r\n'
            'WWW-Authenticate: Digest realm="monero-rpc", nonce="fixture-nonce", algorithm=MD5-sess, qop="auth"'
        )

        testcase = self

        class WireSocket:
            def __init__(self):
                self.sent = bytearray()
                self.closed = False
                self.calls = 0

            def setsockopt(self, *args):
                pass

            def sendall(self, value):
                self.sent.extend(value)

            def settimeout(self, value):
                testcase.assertTrue(0 < value <= 8)

            def close(self):
                self.closed = True

            def makefile(self, *args):
                request = bytes(self.sent).decode("latin-1")
                self.sent.clear()
                requests.append(request)
                self.calls += 1
                code = first if self.calls == 1 else second
                headers = ""
                if code == 401:
                    headers = "WWW-Authenticate: " + challenges + "\r\n"
                if close:
                    headers += "Connection: close\r\n"
                if self.calls > 1:
                    # Independently verify the session nonce and saved credentials.
                    line = next(
                        line for line in request.splitlines() if line.startswith("Authorization: ")
                    )
                    auth = module.parse_keqv_list(
                        module.parse_http_list(line.split("Digest ", 1)[1])
                    )

                    def h(value):
                        return hashlib.md5(value.encode(), usedforsecurity=False).hexdigest()

                    expected = h(
                        h("fixture-user:monero-rpc:" + password)
                        + ":fixture-nonce:"
                        + auth["nc"]
                        + ":"
                        + auth["cnonce"]
                        + ":auth:"
                        + h("GET:/get_info")
                    )
                    if auth["nonce"] != "fixture-nonce" or auth["response"] != expected:
                        code = 401
                    testcase.assertEqual(auth["username"], "fixture-user")
                    testcase.assertEqual(auth["uri"], "/get_info")
                    testcase.assertEqual(auth["algorithm"], "MD5")
                    testcase.assertEqual(auth["qop"], "auth")
                    testcase.assertEqual(auth["nc"], "00000001")
                payload = (
                    body
                    if body is not None
                    else json.dumps({"status": "OK", "synchronized": True}).encode()
                )
                return io.BytesIO(
                    (
                        f"HTTP/1.1 {code} fixture\r\n"
                        + headers
                        + f"Content-Length: {len(payload)}\r\n\r\n"
                    ).encode()
                    + payload
                )

        def connect(address, *args, **kwargs):
            self.assertEqual(address, ("fixture.invalid", 18081))
            wire = WireSocket()
            sockets.append(wire)
            return wire

        with (
            patch.object(socket, "create_connection", side_effect=connect),
            patch.dict(
                "os.environ",
                {"http_proxy": "http://proxy.invalid", "HTTP_PROXY": "http://proxy.invalid"},
            ),
        ):
            try:
                result = module.monero_info(url, "fixture-user", password)
                self.assertEqual(len(sockets), 1)
                self.assertEqual(len(requests), 2)
                self.assertNotIn("Authorization:", requests[0])
                self.assertNotIn("Connection: close", "".join(requests))
                return result
            finally:
                self.assertTrue(all(wire.closed for wire in sockets))

    def test_authenticated_retry_retains_challenged_connection(self):
        self.assertIs(self.exchange()["synchronized"], True)

    def test_saved_password_is_used_in_digest(self):
        self.assertIs(self.exchange(password='quote " slash \\ dollar $$')["synchronized"], True)  # noqa: S106 -- synthetic protocol fixture

    def test_unauthenticated_ok_redirect_closed_session_and_bad_retry_refuse(self):
        for options in (
            {"first": 200},
            {"first": 302},
            {"close": True},
            {"second": 401},
            {"second": 302},
            {"second": 503},
        ):
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.exchange(**options)

    def test_challenge_is_required_and_must_support_monero_md5_auth(self):
        for value in (
            'Basic realm="fixture"',
            'Digest realm="fixture", nonce="n", qop="auth-int"',
            'Digest realm="fixture", qop="auth"',
            'Digest realm="fixture", nonce="n", algorithm=SHA-512, qop="auth"',
        ):
            with self.subTest(value=value), self.assertRaises((ValueError, KeyError)):
                self.exchange(challenge=value)

    def test_oversized_and_invalid_payloads_refuse(self):
        for body in (b"x" * 65537, b"invalid-json"):
            with self.subTest(size=len(body)), self.assertRaises(ValueError):
                self.exchange(body=body)

    def test_endpoint_cannot_supply_credentials_or_redirect_destination(self):
        for url in (
            "ftp://fixture.invalid",
            "http://other:password@fixture.invalid",
            "http://fixture.invalid?target=other",
            "http://fixture.invalid#other",
        ):
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.exchange(url=url)

    def test_connection_errors_propagate_without_any_retry(self):
        with patch.object(socket, "create_connection", side_effect=TimeoutError) as connect:
            with self.assertRaises(TimeoutError):
                module.monero_info("http://fixture.invalid", "fixture-user", "changeme")
            connect.assert_called_once()


if __name__ == "__main__":
    unittest.main()
