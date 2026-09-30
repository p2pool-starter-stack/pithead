"""Exercise daemon restoration verdicts without Docker, network access or credentials."""

import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
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
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.env = Path(self.scratch.name) / ".env"
        self.env.write_text(
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
        response = contextlib.nullcontext(io.StringIO(json.dumps(monero)))
        opener = Mock()
        opener.open.return_value = response
        with (
            patch.object(module.urllib.request, "build_opener", return_value=opener) as build,
            patch.object(module.shutil, "which", return_value="/fixture/docker"),
            patch.object(module.subprocess, "run") as run,
        ):
            run.return_value = types.SimpleNamespace(stdout=json.dumps(tari))
            if error:
                run.side_effect = error
            result = module.probe(self.env)
            handler = build.call_args.args[0]
            self.assertEqual(
                handler.passwd.find_user_password(None, "http://fixture.invalid:18081"),
                credentials,
            )
            opener.open.assert_called_once_with("http://fixture.invalid:18081/get_info", timeout=8)
            if result:
                run.assert_called_once_with(
                    ["/fixture/docker", "exec", "dashboard", "python3", "-c", module.TARI_PROBE],
                    capture_output=True,
                    text=True,
                    timeout=12,
                    check=True,
                )
            return result

    def test_independent_authenticated_sync(self):
        self.assertTrue(self.run_probe())

    def test_rendered_quoted_credentials_are_decoded_without_evaluation(self):
        password = 'space " quote \\ dollar $$ and $(exit 1)'  # noqa: S105 -- synthetic parser fixture
        self.env.write_text(
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
                patch.object(module.urllib.request, "build_opener") as build,
            ):
                before = self.env.read_text()
                self.env.write_text(
                    "\n".join(
                        line for line in before.splitlines() if not line.startswith(key + "=")
                    )
                )
                self.assertFalse(module.probe(self.env))
                build.assert_not_called()
                self.env.write_text(before)

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
                module.urllib.request,
                "build_opener",
                side_effect=ValueError("private-endpoint fixture-password"),
            ),
            contextlib.redirect_stdout(out),
            self.assertRaises(SystemExit) as raised,
        ):
            exec(compile(code, str(SOURCE), "exec"), {"__name__": "__main__"})  # noqa: S102 -- checked-in entrypoint
        self.assertEqual(raised.exception.code, 1)
        self.assertEqual(out.getvalue(), "independent daemon sync not proved\n")

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
