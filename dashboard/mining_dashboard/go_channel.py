import builtins
import json
import math
import os
import secrets
import subprocess
from pathlib import Path


def binary():
    return os.environ.get("PITHEAD_DASHBOARD_GO_BINARY") or str(
        Path(__file__).resolve().parents[2] / "go" / "bin" / "dashboard"
    )


def _pack(value, marker):
    if isinstance(value, float) and not math.isfinite(value):
        return {marker: str(value)}
    if isinstance(value, dict):
        return {key: _pack(item, marker) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_pack(item, marker) for item in value]
    return value


def _unpack(value, marker):
    if isinstance(value, dict):
        if list(value) == [marker]:
            return float(value[marker])
        return {key: _unpack(item, marker) for key, item in value.items()}
    if isinstance(value, list):
        return [_unpack(item, marker) for item in value]
    return value


def call(helper, payload):
    raw = json.dumps(payload)
    marker = secrets.token_hex(16)
    while marker in raw:
        marker = secrets.token_hex(16)
    encoded = json.dumps(_pack(payload, marker), allow_nan=False)
    env = os.environ.copy()
    env["PITHEAD_DASHBOARD_HELPER"] = helper
    try:
        result = subprocess.run(  # noqa: S603
            [binary()],
            input=encoded + "\n",
            text=True,
            capture_output=True,
            env=env,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"native {helper} helper unavailable") from error
    if result.returncode != 0:
        raise RuntimeError(f"native {helper} helper failed")
    return _unpack(response(helper, result.stdout), marker)


def response(helper, output):
    try:
        reply = json.loads(output)
        ok = reply["ok"]
        if ok:
            value = reply["value"]
    except (ValueError, KeyError, TypeError) as error:
        raise RuntimeError(f"native {helper} helper returned invalid data") from error
    if not ok:
        detail = reply.get("error") or {}
        kind = detail.get("kind")
        message = detail.get("message", "native operation failed")
        if kind == "UnicodeDecodeError":
            raise UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid start byte")
        exception = getattr(builtins, kind, RuntimeError) if isinstance(kind, str) else RuntimeError
        if exception is OSError and detail.get("errno"):
            raise OSError(detail["errno"], message)
        if exception not in (OSError, ValueError, KeyError, TypeError):
            exception = RuntimeError
        raise exception(message)
    return value
