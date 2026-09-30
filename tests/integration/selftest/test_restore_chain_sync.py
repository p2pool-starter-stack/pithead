"""Exercise daemon restoration verdicts without Docker, network access or credentials."""

import contextlib
import importlib.util
import io
import json
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
                module.subprocess,
                "run",
                side_effect=ValueError("private-endpoint fixture-password"),
            ) as request,
            contextlib.redirect_stdout(out),
            self.assertRaises(SystemExit) as raised,
        ):
            exec(compile(code, str(SOURCE), "exec"), {"__name__": "__main__"})  # noqa: S102 -- checked-in entrypoint
        request.assert_called_once()
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
    """Pure tests for libcurl's private input and mandatory session evidence."""

    def exchange(self, headers=None, counts="1 200 0", body=None, password="changeme"):  # noqa: S107 -- synthetic fixture
        if headers is None:
            headers = (
                'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Digest realm="fixture", '
                'nonce="fixture-nonce", qop="auth"\r\nContent-Length: 0\r\n\r\n'
                "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
            )
        if body is None:
            body = json.dumps({"status": "OK", "synchronized": True})
        header_path = None

        def transport(argv, **kwargs):
            nonlocal header_path
            self.assertEqual(argv[:3], ["/fixture/curl", "-q", "-fsS"])
            for flag, value in (
                ("--max-time", "8"),
                ("--max-filesize", "65536"),
                ("--noproxy", "*"),
                ("--proto", "=http,https"),
                ("-K", "-"),
                ("--url", "http://fixture.invalid:18081/get_info"),
            ):
                self.assertEqual(argv[argv.index(flag) + 1], value)
            self.assertIn("--digest", argv)
            self.assertIn("--no-location", argv)
            self.assertIn("--http1.1", argv)
            self.assertNotIn("--basic", argv)
            self.assertNotIn("fixture-user", " ".join(argv))
            self.assertNotIn(password, " ".join(argv))
            self.assertEqual(
                kwargs,
                dict(
                    input="user = "
                    + json.dumps("fixture-user:" + password, ensure_ascii=False)
                    + "\n",
                    capture_output=True,
                    text=True,
                    timeout=10,
                    check=True,
                ),
            )
            header_path = Path(argv[argv.index("--dump-header") + 1])
            header_path.write_bytes(headers.encode("iso-8859-1"))
            return types.SimpleNamespace(stdout=body + "\n" + counts)

        with (
            patch.object(module.shutil, "which", return_value="/fixture/curl"),
            patch.object(module.subprocess, "run", side_effect=transport) as run,
        ):
            try:
                result = module.monero_info(
                    "http://fixture.invalid:18081", "fixture-user", password
                )
                run.assert_called_once()
                return result
            finally:
                if header_path:
                    self.assertFalse(header_path.exists())

    def test_libcurl_digest_uses_private_stdin_and_bounded_direct_transport(self):
        self.assertIs(self.exchange()["synchronized"], True)
        self.assertIs(self.exchange(password='quote " slash \\ dollar $$')["synchronized"], True)  # noqa: S106 -- synthetic fixture

    def test_reconnect_redirect_or_failed_authentication_cannot_pass(self):
        for counts in ("2 200 0", "0 200 0", "1 302 0", "1 200 1", "1 401 0", ""):
            with self.subTest(counts=counts), self.assertRaises(ValueError):
                self.exchange(counts=counts)

    def test_actual_digest_challenge_and_final_ok_are_required(self):
        for headers in (
            "HTTP/1.1 200 OK\r\n\r\n",
            'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="fixture"\r\n\r\nHTTP/1.1 200 OK\r\n\r\n',
            'HTTP/1.1 302 Found\r\nWWW-Authenticate: Digest realm="fixture"\r\n\r\nHTTP/1.1 200 OK\r\n\r\n',
            'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Digest realm="fixture"\r\n\r\nHTTP/1.1 401 Unauthorized\r\n\r\n',
            "HTTP/1.1 401 Unauthorized\r\n\r\nHTTP/1.1 200 OK\r\n\r\n",
        ):
            with self.subTest(headers=headers), self.assertRaises(ValueError):
                self.exchange(headers=headers)

    def test_response_and_headers_are_bounded_and_json_is_required(self):
        for options in ({"body": "x" * 65537}, {"body": "invalid-json"}, {"headers": "x" * 16385}):
            with self.subTest(options=list(options)), self.assertRaises(ValueError):
                self.exchange(**options)

    def test_endpoint_and_credentials_cannot_inject_transport_options(self):
        for url, password in (
            ("ftp://fixture.invalid", "changeme"),
            ("http://other:password@fixture.invalid", "changeme"),
            ("http://fixture.invalid?target=other", "changeme"),
            ("http://fixture.invalid#other", "changeme"),
            ("http://fixture.invalid", "line\nbreak"),
            ("http://fixture.invalid", "nul\x00byte"),
        ):
            with (
                self.subTest(url=url),
                patch.object(module.subprocess, "run") as run,
                self.assertRaises(ValueError),
            ):
                module.monero_info(url, "fixture-user", password)
            run.assert_not_called()

    def test_missing_transport_and_transport_failure_refuse(self):
        with patch.object(module.shutil, "which", return_value=None), self.assertRaises(ValueError):
            module.monero_info("http://fixture.invalid", "fixture-user", "changeme")
        for error in (
            subprocess.TimeoutExpired("private", 10),
            subprocess.CalledProcessError(1, "private"),
        ):
            with (
                self.subTest(error=error),
                patch.object(module.shutil, "which", return_value="/fixture/curl"),
                patch.object(module.subprocess, "run", side_effect=error) as run,
                self.assertRaises(type(error)),
            ):
                module.monero_info("http://fixture.invalid", "fixture-user", "changeme")
            run.assert_called_once()


if __name__ == "__main__":
    unittest.main()
