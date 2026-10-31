#!/usr/bin/env bash
set -euo pipefail
echo "== Privacy peering fixture guards =="
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
python3 - "$ROOT/tests/integration/profile-peering.py" <<'PY'
import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
import sys
from unittest.mock import MagicMock, mock_open, patch

spec = importlib.util.spec_from_file_location("profile_peering", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
onion = "a" * 56 + ".onion"
assert module.outgoing_onion(["O,12,3,P2Pool,100," + onion + ":37888"])
assert not module.outgoing_onion(["I,12,3,P2Pool,100," + onion + ":37888"])
assert not module.outgoing_onion(["O,12,3,P2Pool,100,127.0.0.1:37888"])
assert not module.outgoing_onion(["O,12,3,P2Pool,100," + onion], "b" * 56 + ".onion")
for count, accepted in (("0", False), ("1", True)):
    with patch.object(module, "command", return_value=count):
        assert module.probe("tor", "127.0.0.1", 37888) is accepted
for address, port in (("bad-address", 37888), ("127.0.0.1", 3333), ("127.0.0.1", 18081)):
    try:
        module.probe("tor", address, port)
    except ValueError:
        pass
    else:
        raise AssertionError("non-peering target accepted")
with patch.object(module.subprocess, "run", side_effect=subprocess.TimeoutExpired(["secret"], 60)):
    try:
        module.command("fixture")
    except RuntimeError as exc:
        assert "secret" not in str(exc)
    else:
        raise AssertionError("timed-out fixture accepted")
def probe_response(chunks):
    connection = MagicMock()
    connection.__enter__.return_value = connection
    connection.recv.side_effect = chunks
    with patch.object(module.socket, "create_connection", return_value=connection):
        result = module.onion_probe("127.0.0.3", onion, 37888)
    assert onion not in str(result) and "127.0.0.3" not in str(result)
    return result
assert probe_response([b"\x05", b"\x00", b"\x05\x00\x00\x01", b"\x00" * 4, b"\x00" * 2, b"x"]) == {
    "stage": "challenge", "socks_reply": 0, "challenge_received": True
}
for address_type, address in ((4, [b"\x00" * 16]), (3, [b"\x03", b"abc"])):
    result = probe_response([b"\x05\x00", bytes((5, 0, 0, address_type))] + address + [b"\x00" * 2, b"x"])
    assert result["challenge_received"] is True
with patch.object(module.time, "monotonic", side_effect=[0, 16]):
    assert probe_response([]) == {"stage": "greeting", "failure": "timeout"}
assert probe_response([b"\x05\x00", b"\x05\x04\x00\x01"]) == {"stage": "reply", "socks_reply": 4}
assert probe_response([b"\x05\xff"]) == {"stage": "greeting", "failure": "invalid-greeting"}
assert probe_response([b"\x05\x00", b""]) == {"stage": "reply", "failure": "eof"}
assert probe_response([b"\x05\x00", TimeoutError("private timeout")]) == {"stage": "reply", "failure": "timeout"}
assert probe_response([b"\x05\x00", b"\x05\x00\x00\x09"]) == {"stage": "reply", "socks_reply": 0, "failure": "invalid-address-type"}
assert probe_response([b"\x05\x00", b"\x04\x00\x00\x01"]) == {"stage": "reply", "failure": "invalid-reply"}
with patch.object(module.socket, "create_connection", side_effect=OSError("private endpoint")):
    assert module.onion_probe("127.0.0.3", onion, 37888) == {"stage": "connect", "failure": "socket"}
with patch.object(module, "command", return_value="Bootstrapped 100% private-endpoint\nNo more HSDir available to query\nis failing a very large amount of circuits") as tor_log:
    result = module.tor_diagnostics("fixture")
    assert "private-endpoint" not in str(result)
    tor_log.assert_called_once_with("docker", "logs", "--tail", "100", "fixture")
    assert module.tor_diagnostics("fixture") == {
        "bootstrap_seen": True, "descriptor_lookup_failure_seen": True, "circuit_failure_seen": True
    }
with patch.object(module, "command", return_value="private-endpoint"):
    assert not any(module.tor_diagnostics("fixture").values())
with patch.object(module, "command", side_effect=RuntimeError("private-endpoint")):
    assert module.tor_diagnostics("fixture") == {"logs_unavailable": True}
for proxy, host, port in (("invalid", onion, 37888), ("127.0.0.3", "invalid", 37888), ("127.0.0.3", onion, 3333)):
    with patch.object(module.socket, "create_connection") as connect:
        try:
            module.onion_probe(proxy, host, port)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid onion diagnostic target accepted")
        connect.assert_not_called()
with patch.object(module, "inspect", return_value={"State": {"Running": True, "ExitCode": 0}}), patch.object(
    module, "command", side_effect=[module.json.dumps({"peers": ["O," + "b" * 56 + ".onion"]}), ""]
):
    result = module.diagnostics("fixture", "/stats", onion)
    assert result["outbound_onion"] and result["outbound_target"] is False
secret = "credential-value-and-private-endpoint"
with patch.object(module, "inspect", return_value={"State": {"Running": False, "ExitCode": 78}}), patch.object(
    module, "command", side_effect=[RuntimeError(secret), "RPC connection failed " + secret]
):
    result = module.diagnostics("fixture", "/stats")
    assert result["running"] is False and result["exit_code"] == 78
    assert result["stats_available"] is False and result["rpc_error"] is True
    assert secret not in str(result)
with patch.object(module, "inspect", side_effect=RuntimeError(secret)), patch.object(
    module, "command", side_effect=[module.json.dumps({"peers": ["I,secret", "O," + onion]}), RuntimeError(secret)]
):
    result = module.diagnostics("fixture", "/stats")
    assert result["state_unavailable"] and result["logs_unavailable"]
    assert result["inbound"] == 1 and result["outbound_onion"]
    assert secret not in str(result) and onion not in str(result)
with patch.object(module, "inspect", return_value={"State": {"Running": False, "ExitCode": None}}), patch.object(
    module, "command", side_effect=['{"peers": null}', ""]
):
    result = module.diagnostics("fixture", "/stats")
    assert result["state_unavailable"] and result["stats_available"] is False
with TemporaryDirectory() as image_workdir:
    argv = ["--host", "node", "--rpc-port", "18081", "--rpc-login", secret,
            "--zmq-port", "18083", "--wallet", secret]
    network = {"candidate": {"IPAddress": "127.0.0.2"}}
    candidate = {"Config": {"Cmd": argv, "Image": "candidate-image", "WorkingDir": image_workdir},
                 "HostConfig": {}, "NetworkSettings": {"Networks": network}}
    def fixture_inspect(name):
        if name == "p2pool":
            return candidate
        if name == "tor":
            return {"Config": {"Image": "tor-image"}}
        if name == "monerod":
            return {"NetworkSettings": {"Networks": network}}
        return {"NetworkSettings": {"Networks": {"bridge": {"IPAddress": "127.0.0.3"}}}}
    created = []
    def fixture_command(*args):
        if args[:2] == ("docker", "create"):
            data_path = args[args.index("--data-api") + 1]
            assert Path(data_path).is_dir(), "fixture data API parent does not exist"
            assert data_path == image_workdir
            created.append(args)
        if args[:2] == ("docker", "logs"):
            return "Bootstrapped 100%"
        if args[:2] == ("docker", "exec"):
            if args[2] != "p2pool":
                assert args[-1] == image_workdir + "/local/p2p"
            return module.json.dumps({"peers": ["I,fixture", "O," + onion + ":37888"]})
        return ""
    config = "P2POOL_PORT=37888\nPITHEAD_PROFILE=privacy\nTOR_EGRESS_FIREWALL=true\nP2POOL_ONION_ADDRESS=" + onion
    connection = MagicMock()
    connection.__enter__.return_value.recv.return_value = b""
    output = io.StringIO()
    with patch("builtins.open", mock_open(read_data=config)), patch.object(module, "inspect", side_effect=fixture_inspect), patch.object(
        module, "command", side_effect=fixture_command
    ), patch.object(module, "probe", side_effect=lambda name, *_: name == "tor"), patch.object(
        module.socket, "create_connection", return_value=connection
    ), patch.object(module.time, "sleep"), patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), redirect_stdout(output):
        module.main()
    assert len(created) == 1 and "PASS:" in output.getvalue()
    assert secret not in output.getvalue()
    output = io.StringIO()
    with patch("builtins.open", mock_open(read_data=config)), patch.object(module, "inspect", side_effect=fixture_inspect), patch.object(
        module, "command", side_effect=fixture_command
    ), patch.object(module, "probe", side_effect=lambda name, *_: name == "tor"), patch.object(
        module.socket, "create_connection", return_value=connection
    ), patch.object(module.time, "monotonic", side_effect=[0, 0, 1000]), patch.object(
        module, "onion_probe", return_value={"stage": "reply", "socks_reply": 4}
    ) as onion_diagnostic, patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as cleanup, redirect_stdout(output):
        try:
            module.main()
        except RuntimeError as exc:
            assert str(exc) == "Privacy peer handshake deadline"
        else:
            raise AssertionError("deadline accepted as a passing handshake")
    diagnostic = module.json.loads(output.getvalue())
    assert diagnostic["fixture"]["outbound_target"] is True
    assert diagnostic["fixture_tor"]["bootstrap_seen"] is True
    assert diagnostic["onion_probe"] == {"stage": "reply", "socks_reply": 4}
    onion_diagnostic.assert_called_once_with("127.0.0.3", onion, 37888)
    assert cleanup.call_count == 2 and secret not in output.getvalue() and onion not in output.getvalue()
    for invalid_workdir in ("", None, "relative"):
        candidate["Config"]["WorkingDir"] = invalid_workdir
        with patch("builtins.open", mock_open(read_data=config)), patch.object(module, "inspect", side_effect=fixture_inspect):
            try:
                module.main()
            except RuntimeError as exc:
                assert str(exc) == "candidate image working directory missing"
            else:
                raise AssertionError("missing fixture API parent accepted")
print("PASS: onion direction, bridge probes, bounded failures, diagnostics and existing fixture API directory")
PY
