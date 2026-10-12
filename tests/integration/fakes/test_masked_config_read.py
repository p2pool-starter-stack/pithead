"""Raw host source → actual CLI masked renderer → actual dashboard config reader."""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required for masked-config contract tests")
sys.path.insert(0, str(ROOT / "dashboard"))
from mining_dashboard.service import control_service  # noqa: E402


def render(source, control):
    return subprocess.run(  # noqa: S603 — fixed source paths, JSON only passes through a file
        [
            BASH,
            "-c",
            'source "$1"; source "$2"; CONFIG_FILE="$3"; APP_UID="$5"; APP_GID="$6"; '
            'warn() { printf "%s\\n" "$*" >&2; }; render_masked_config "$4"',
            "test",
            str(ROOT / "lib/pithead/22a-config-document.sh"),
            str(ROOT / "lib/pithead/30-release-fetch-and-masked-config.sh"),
            str(source),
            str(control),
            str(os.getuid()),
            str(os.getgid()),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


VALID = {"dashboard": {"auth": {"password": "opaque"}}, "p2pool": {"pool": "mini"}}


@pytest.mark.parametrize(
    ("raw", "path", "hidden"),
    [
        ('{"monero":{},"monero":{}}', "monero", ""),
        (
            '{"dashboard":{"auth":{"password":"first","password":"last"}}}',
            "dashboard.auth.password",
            "first",
        ),
        (
            '{"dashboard":{"auth":{"password":"pAsTe_private"}}}',
            "dashboard.auth.password",
            "pAsTe_private",
        ),
        (
            '{"workers":{"list":[{"api_token":"YOUR_private"}]}}',
            "workers.list[0].api_token",
            "YOUR_private",
        ),
        (
            '{"notifications":{"webhooks":["PASTE_hook"]}}',
            "notifications.webhooks[0]",
            "PASTE_hook",
        ),
        ('{"broken":', "not valid JSON", ""),
    ],
)
def test_invalid_raw_source_refuses_real_dashboard_read(tmp_path, monkeypatch, raw, path, hidden):
    source = tmp_path / "raw.json"
    control = tmp_path / "control"
    masked = control / "masked/config.json"
    source.write_text(json.dumps(VALID))
    assert render(source, control).returncode == 0
    monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", str(masked))
    monkeypatch.setattr(control_service.config, "HOST_REFERENCE_PATH", str(tmp_path / "missing"))
    assert control_service.read_config()["p2pool"]["pool"] == "mini"
    tokens = masked.parent / "worker-read-tokens.json"
    tokens.write_text('{"credentials":"old"}')
    source.write_text(raw)
    result = render(source, control)
    assert result.returncode == 1
    assert path in result.stderr
    assert source.read_text() == raw
    assert not tokens.exists()
    with pytest.raises(ValueError, match=path.replace("[", r"\[").replace("]", r"\]")):
        control_service.read_config()
    if hidden:
        assert hidden not in masked.read_text()
        assert hidden not in result.stderr
    # A corrected raw source clears the refusal through the same rendering boundary.
    source.write_text(json.dumps(VALID))
    assert render(source, control).returncode == 0
    cfg = control_service.read_config()
    assert cfg["dashboard"]["auth"]["password"] == {"__secret__": True}
    assert cfg["p2pool"]["pool"] == "mini"
