"""Dashboard raw JSON validation precedes normalization and masks no bad values."""

import io
import json
import re

import pytest

from mining_dashboard.config import documents

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
def test_duplicate_keys_refused(text, path):
    with pytest.raises(ValueError, match="duplicate key") as caught:
        documents.loads(text)
    assert path in str(caught.value)


@pytest.mark.parametrize("path", SECRETS)
@pytest.mark.parametrize("value", ["PASTE_secret", "your_secret", "pAsTe_secret", "YoUr_secret"])
def test_placeholder_paths_refused(path, value):
    text = json.dumps(candidate(path, value))
    with pytest.raises(ValueError, match="placeholder value") as caught:
        documents.load_config(io.StringIO(text))
    assert path in str(caught.value)


@pytest.mark.parametrize(
    "cfg",
    [
        {"a": {"x": 1}, "b": {"x": 2}},
        {"workers": [{"token": "opaque"}, {"token": "another"}]},
        {"enabled": False, "unset": None, "password": "", "host": "auto", "text": "prefix_YOUR_"},
        {"dashboard": {"auth": {"password": {"__secret__": True}}}},
    ],
)
def test_valid_documents_unchanged(cfg):
    text = json.dumps(cfg)
    assert documents.load_config(io.StringIO(text)) == cfg


@pytest.mark.parametrize("text", ["{", '{"a":', "[]\n{}"])
def test_malformed_json_refused(text):
    with pytest.raises(ValueError):
        documents.loads(text)


def test_untrusted_key_diagnostics_escape_controls():
    text = '{"bad\\nkey":{"secret":"YOUR_value"}}'
    with pytest.raises(ValueError) as caught:
        documents.load_config(io.StringIO(text))
    assert "\n" not in str(caught.value)
    assert "YOUR_value" not in str(caught.value)
