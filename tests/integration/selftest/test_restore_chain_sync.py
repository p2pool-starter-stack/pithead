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
            patch.object(module.shutil, "which", side_effect=lambda tool: "/fixture/" + tool),
            patch.object(module.subprocess, "run") as run,
        ):
            run.side_effect = [
                types.SimpleNamespace(stdout=json.dumps(monero)),
                error or types.SimpleNamespace(stdout=json.dumps(tari)),
            ]
            result = module.probe(self.env)
            curl = run.call_args_list[0]
            self.assertEqual(
                curl.args[0],
                [
                    "/fixture/curl",
                    "-q",
                    "-fsS",
                    "--max-filesize",
                    "65536",
                    "--max-time",
                    "8",
                    "--digest",
                    "-K",
                    "-",
                    "--url",
                    "http://fixture.invalid:18081/get_info",
                ],
            )
            self.assertEqual(
                curl.kwargs,
                dict(
                    input="user = " + json.dumps(":".join(credentials), ensure_ascii=False) + "\n",
                    capture_output=True,
                    text=True,
                    timeout=10,
                    check=True,
                ),
            )
            if result:
                self.assertEqual(run.call_count, 2)
                self.assertEqual(
                    run.call_args.args[0],
                    ["/fixture/docker", "exec", "dashboard", "python3", "-c", module.TARI_PROBE],
                )
                self.assertEqual(
                    run.call_args.kwargs,
                    dict(capture_output=True, text=True, timeout=12, check=True),
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
        for error in (
            subprocess.TimeoutExpired("private-endpoint", 10),
            subprocess.CalledProcessError(22, "curl", stderr="fixture-password"),
        ):
            with (
                self.subTest(error=error),
                patch.object(module.shutil, "which", return_value="/fixture/curl"),
                patch.object(module.subprocess, "run", side_effect=error) as run,
                self.assertRaises(type(error)),
            ):
                module.probe(self.env)
            self.assertEqual(run.call_count, 1)
            self.assertEqual(module.STAGE, "monero-rpc")
        with (
            patch.object(module.shutil, "which", return_value=None),
            patch.object(module.subprocess, "run") as run,
        ):
            self.assertFalse(module.probe(self.env))
            run.assert_not_called()

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
            ),
            contextlib.redirect_stdout(out),
            self.assertRaises(SystemExit) as raised,
        ):
            exec(compile(code, str(SOURCE), "exec"), {"__name__": "__main__"})  # noqa: S102 -- checked-in entrypoint
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


if __name__ == "__main__":
    unittest.main()
