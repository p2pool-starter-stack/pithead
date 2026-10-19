#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 - "$HERE/console-login-probe.py" <<'PY'
import copy
import ctypes
import importlib.util
import sys
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
good = {
    "config": {"dashboard": {"auth": {"password": "new-password"}}},
    "shadow": "root:$fixture$new:20000:0:99999:7:::",
    "status": "root P 2026-01-01 0 99999 7 -1",
    "mount": {"target": "/etc", "fstype": "overlay", "options": "rw,lowerdir=/etc,upperdir=/run/pithead-etc/upper,workdir=/run/pithead-etc/work"},
    "backing": "tmpfs",
    "matches": lambda password, hashed: password == "new-password" and hashed == "$fixture$new",
}
assert probe.console_login_valid(**good)
for field, value in (
    ("config", {}), ("shadow", ""), ("shadow", "root:!:20000:0:99999:7:::"),
    ("shadow", "root:$fixture$old:20000:0:99999:7:::"),
    ("shadow", good["shadow"] + "\n" + good["shadow"]),
    ("status", "root L"), ("status", "root NP"), ("status", ""),
    ("backing", "ext4"), ("backing", ""),
):
    case = copy.deepcopy(good)
    case[field] = value
    assert not probe.console_login_valid(**case), field
for field, value in (
    ("target", "/"), ("fstype", "ext4"), ("options", "rw"),
    ("options", "upperdir=/data/pithead-etc/upper"),
    ("options", "upperdir=/run/../data/upper"),
    ("options", "upperdir=/runtime/upper"),
):
    case = copy.deepcopy(good)
    case["mount"][field] = value
    assert not probe.console_login_valid(**case), field
for result, expected in ((b"$fixture$new", True), (b"$fixture$old", False), (None, False), (b"*0", False)):
    crypt = Mock(return_value=result)
    with patch.object(ctypes, "CDLL", return_value=Mock(crypt=crypt)):
        assert probe.password_matches("new-password", "$fixture$new") == expected
    crypt.assert_called_once_with(b"new-password", b"$fixture$new")
with patch("builtins.open", side_effect=OSError):
    assert probe.main() == 1
print("PASS: console hash parity, password status, volatile upperdir and fail-closed reads")
PY
