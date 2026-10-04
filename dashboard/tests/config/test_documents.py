"""Raw JSON validation must precede normalization at both runtime boundaries."""

import io
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

from mining_dashboard.config import documents

BASH = shutil.which("bash")
assert BASH is not None

ROOT = Path(__file__).resolve().parents[3]
SECRETS = [
    "dashboard.auth.password",
    "telegram.bot_token",
    "telegram.chat_id",
    "monero.node_username",
    "monero.node_password",
    "monero.view_key",
    "tari.view_key",
    "tari.spend_public_key",
    "workers.api_token",
    "workers.api_auth",
    "p2pool.stratum_password",
    "healthchecks.ping_url",
    "notifications.ntfy.url",
    "notifications.ntfy.token",
    "xvb.standby.source",
    "workers.list[0].token",
    "workers.list[0].api_token",
    "notifications.webhooks[0]",
    "dashboard.host",
    "monero.wallet_address",
    "tari.wallet_address",
]


def candidate(path, value):
    cfg = value
    for part in reversed(path.split(".")):
        match = re.fullmatch(r"(.+)\[0\]", part)
        cfg = {match[1]: [cfg]} if match else {part: cfg}
    return cfg


def cli_error(tmp_path, text, request=False):
    path = tmp_path / "config.json"
    path.write_text(text)
    # Source just the parser: no runtime, containers, or stack mutation.
    result = subprocess.run(  # noqa: S603 — fixed command; file contents never become shell code
        [
            BASH,
            "-c",
            'source "$1"; config_document_error "$2" "$3"',
            "test",
            str(ROOT / "lib/pithead/22a-config-document.sh"),
            str(path),
            "request" if request else "config",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    assert not result.stderr
    return result


@pytest.mark.parametrize(
    ("text", "path"),
    [
        ('{"monero":{},"monero":{}}', "monero"),
        (
            '{"dashboard":{"auth":{"password":"first","password":"last"}}}',
            "dashboard.auth.password",
        ),
        ('{"workers":{"list":[{"token":"first","token":"last"}]}}', "workers.list[0].token"),
        ('{"monero":{},"\\u006donero":{}}', "monero"),
        ('{"a":{"x":1},"a":{"y":2}}', "a"),
        ('{"a":null,"a":0}', "a"),
    ],
)
def test_duplicate_keys_refused_by_both_parsers(tmp_path, text, path):
    with pytest.raises(ValueError, match="duplicate key") as caught:
        documents.loads(text)
    assert path in str(caught.value)
    result = cli_error(tmp_path, text)
    assert result.returncode == 1
    assert path in result.stdout
    assert "duplicate key" in result.stdout
    assert "first" not in result.stdout and "last" not in result.stdout


@pytest.mark.parametrize("path", SECRETS)
@pytest.mark.parametrize("value", ["PASTE_secret", "your_secret", "pAsTe_secret", "YoUr_secret"])
def test_placeholder_paths_refused_by_both_parsers(tmp_path, path, value):
    text = json.dumps(candidate(path, value))
    with pytest.raises(ValueError, match="placeholder value") as caught:
        documents.load_config(io.StringIO(text))
    assert path in str(caught.value)
    result = cli_error(tmp_path, text)
    assert result.returncode == 1
    assert path in result.stdout
    assert value not in result.stdout


@pytest.mark.parametrize(
    "cfg",
    [
        {"a": {"x": 1}, "b": {"x": 2}},
        {"workers": [{"token": "opaque"}, {"token": "another"}]},
        {"enabled": False, "unset": None, "password": "", "host": "auto", "text": "prefix_YOUR_"},
        {"dashboard": {"auth": {"password": {"__secret__": True}}}},
    ],
)
def test_valid_documents_unchanged(tmp_path, cfg):
    text = json.dumps(cfg)
    assert documents.load_config(io.StringIO(text)) == cfg
    assert cli_error(tmp_path, text).returncode == 0


def test_request_checks_raw_duplicates_and_only_config_placeholders(tmp_path):
    text = '{"actor":"YOUR_user","config":{"telegram":{"bot_token":"opaque"}}}'
    assert cli_error(tmp_path, text, request=True).returncode == 0
    text = '{"config":{"dashboard":{"host":"PASTE_host"}}}'
    result = cli_error(tmp_path, text, request=True)
    assert result.returncode == 1 and "dashboard.host" in result.stdout
    result = cli_error(tmp_path, '{"config":{},"config":{}}', request=True)
    assert result.returncode == 1 and "duplicate key" in result.stdout


@pytest.mark.parametrize("text", ["{", '{"a":', "[]\n{}"])
def test_malformed_json_refused(tmp_path, text):
    with pytest.raises(ValueError):
        documents.loads(text)
    result = cli_error(tmp_path, text)
    assert result.returncode == 1 and "not valid JSON" in result.stdout


def test_unreadable_cli_document(tmp_path):
    result = subprocess.run(  # noqa: S603 — fixed command; file contents never become shell code
        [
            BASH,
            "-c",
            'source "$1"; config_document_error "$2"',
            "test",
            str(ROOT / "lib/pithead/22a-config-document.sh"),
            str(tmp_path / "missing"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert "could not read config document" in result.stdout


def test_untrusted_key_diagnostics_escape_controls(tmp_path):
    text = '{"bad\\nkey":{"secret":"YOUR_value"}}'
    with pytest.raises(ValueError) as caught:
        documents.load_config(io.StringIO(text))
    assert "\n" not in str(caught.value)
    result = cli_error(tmp_path, text)
    assert result.returncode == 1
    assert len(result.stdout.splitlines()) == 1
    assert "YOUR_value" not in result.stdout


def test_cli_deep_document_refused(tmp_path):
    result = cli_error(tmp_path, '{"value":' + "[" * 1200 + "0" + "]" * 1200 + "}")
    assert result.returncode == 1
    assert "nested too deeply" in result.stdout
