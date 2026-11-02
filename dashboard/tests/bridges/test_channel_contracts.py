import json
import math
import subprocess
from types import SimpleNamespace

import pytest

from mining_dashboard import go_channel


def test_binary_override_and_default(monkeypatch):
    monkeypatch.delenv("PITHEAD_DASHBOARD_GO_BINARY", raising=False)
    assert go_channel.binary().endswith("/go/bin/dashboard")
    monkeypatch.setenv("PITHEAD_DASHBOARD_GO_BINARY", "native-dashboard")
    assert go_channel.binary() == "native-dashboard"


def test_channel_preserves_nonfinite_values_without_marker_collision(monkeypatch):
    selected = iter(("collision", "marker"))
    monkeypatch.setattr(go_channel.secrets, "token_hex", lambda _size: next(selected))
    monkeypatch.setenv("PITHEAD_DASHBOARD_GO_BINARY", "native-dashboard")
    captured = []

    def run(argv, **kwargs):
        captured.append((argv, kwargs))
        value = {"nested": [{"marker": "nan"}, {"marker": "inf"}, {"marker": "-inf"}]}
        return SimpleNamespace(returncode=0, stdout=json.dumps({"ok": True, "value": value}))

    monkeypatch.setattr(go_channel.subprocess, "run", run)
    payload = {"operation": "contract", "envelope": True, "args": ("collision", math.inf)}
    result = go_channel.call("fleet", payload)
    assert math.isnan(result["nested"][0])
    assert result["nested"][1:] == [math.inf, -math.inf]
    argv, options = captured[0]
    assert argv == ["native-dashboard"]
    assert options["env"]["PITHEAD_DASHBOARD_HELPER"] == "fleet"
    assert options["timeout"] == 30
    assert json.loads(options["input"]) == {
        "operation": "contract",
        "envelope": True,
        "args": ["collision", {"marker": "inf"}],
        "nonfinite_marker": "marker",
    }
    assert payload["args"][1] == math.inf


def test_nonfleet_channel_does_not_add_envelope_metadata(monkeypatch):
    captured = []

    def run(_argv, **kwargs):
        captured.append(json.loads(kwargs["input"]))
        return SimpleNamespace(returncode=0, stdout='{"ok":true,"value":[1,null]}')

    monkeypatch.setattr(go_channel.subprocess, "run", run)
    assert go_channel.call("control", {"envelope": True}) == [1, None]
    assert captured == [{"envelope": True}]


@pytest.mark.parametrize("error", [OSError("missing"), subprocess.TimeoutExpired("helper", 30)])
def test_channel_transport_errors_are_chained(monkeypatch, error):
    def run(*_args, **_kwargs):
        raise error

    monkeypatch.setattr(go_channel.subprocess, "run", run)
    with pytest.raises(RuntimeError, match="helper unavailable") as caught:
        go_channel.call("control", {})
    assert caught.value.__cause__ is error


def test_channel_nonzero_exit_does_not_consume_reply(monkeypatch):
    monkeypatch.setattr(
        go_channel.subprocess,
        "run",
        lambda *_args, **_kwargs: SimpleNamespace(returncode=125, stdout="not JSON"),
    )
    with pytest.raises(RuntimeError, match="helper failed"):
        go_channel.call("control", {})


@pytest.mark.parametrize("raw", ["", "[]", "null", "{}", '{"ok":1}', '{"ok":true}'])
def test_channel_rejects_invalid_success_frames(raw):
    with pytest.raises(RuntimeError, match="returned invalid data"):
        go_channel.response("control", raw)


@pytest.mark.parametrize(
    ("kind", "expected"),
    [
        ("ValueError", ValueError),
        ("KeyError", KeyError),
        ("TypeError", TypeError),
        ("AttributeError", AttributeError),
        ("OverflowError", OverflowError),
        ("SystemExit", RuntimeError),
        (None, RuntimeError),
        ("missing", RuntimeError),
        ("UnicodeDecodeError", UnicodeDecodeError),
    ],
)
def test_channel_error_types_are_allowlisted(kind, expected):
    raw = json.dumps({"ok": False, "error": {"kind": kind, "message": "contract failure"}})
    with pytest.raises(expected):
        go_channel.response("control", raw)


def test_channel_reconstructs_oserror_errno():
    with pytest.raises(OSError) as caught:
        go_channel.response(
            "control", '{"ok":false,"error":{"kind":"OSError","errno":13,"message":"denied"}}'
        )
    assert caught.value.errno == 13
    assert "denied" in str(caught.value)


def test_channel_default_error_and_nested_ordinary_values():
    with pytest.raises(RuntimeError, match="native operation failed"):
        go_channel.response("control", '{"ok":false}')
    assert go_channel._unpack({"ordinary": [1, {"other": "inf"}]}, "marker") == {
        "ordinary": [1, {"other": "inf"}]
    }
