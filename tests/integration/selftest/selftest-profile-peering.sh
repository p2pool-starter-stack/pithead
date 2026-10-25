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
