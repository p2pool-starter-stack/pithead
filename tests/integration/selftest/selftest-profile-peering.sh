#!/usr/bin/env bash
set -euo pipefail
echo "== Privacy peering fixture guards =="
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
python3 - "$ROOT/tests/integration/profile-peering.py" <<'PY'
import importlib.util
import subprocess
import sys
from unittest.mock import patch

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
print("PASS: onion direction, bridge probes, bounded failures and credential-free diagnostics")
PY
