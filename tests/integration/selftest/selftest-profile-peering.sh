#!/usr/bin/env bash
set -euo pipefail
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
print("PASS: onion peer direction, bridge probe, peering port and bounded failure controls")
PY
