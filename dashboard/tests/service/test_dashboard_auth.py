import json
import secrets
import uuid
from datetime import UTC, datetime
from unittest.mock import MagicMock

import bcrypt
import pytest

from mining_dashboard.service import control_service, dashboard_auth
from mining_dashboard.service.data_service import DataService


@pytest.fixture
def document(tmp_path, monkeypatch):
    path = tmp_path / "auth.json"
    monkeypatch.setenv("DASHBOARD_AUTH_FILE", str(path))
    return path


def test_auth_unset_preserves_disabled_default(monkeypatch):
    monkeypatch.delenv("DASHBOARD_AUTH_FILE", raising=False)
    assert dashboard_auth.load() == {"users": {}, "metrics_password_hash": "", "configured": False}


@pytest.mark.parametrize(
    "value",
    [
        [],
        {},
        {"users": {}},
        {"users": [None]},
        {"users": [{"name": "bad/name"}]},
        {"users": [], "metrics_password_hash": None},
    ],
)
def test_invalid_auth_configuration_is_refused(document, value):
    document.write_text(json.dumps(value))
    with pytest.raises(ValueError):
        dashboard_auth.load()


def test_duplicate_and_non_admin_accounts_are_refused(document):
    hashed = bcrypt.hashpw(secrets.token_bytes(18), bcrypt.gensalt(rounds=4)).decode()
    user = {"name": "owner", "role": "admin", "password_hash": hashed}
    document.write_text(json.dumps({"users": [user, user]}))
    with pytest.raises(ValueError):
        dashboard_auth.load()
    user["role"] = "viewer"
    document.write_text(json.dumps({"users": [user]}))
    with pytest.raises(ValueError):
        dashboard_auth.load()
    user["role"] = "admin"
    user["password_hash"] = hashed.replace("$04$", "$31$")
    document.write_text(json.dumps({"users": [user]}))
    with pytest.raises(ValueError):
        dashboard_auth.load()


def test_password_hash_roundtrip_and_long_input_refusal():
    password = secrets.token_urlsafe(20)
    hashed = dashboard_auth.hash_password(password)
    assert dashboard_auth.verify(password, hashed)
    assert not dashboard_auth.verify(secrets.token_urlsafe(20), hashed)
    for invalid in ("", "x" * 73, "é" * 37, "a\0b", None, "\ud800"):
        assert not dashboard_auth.verify(invalid, hashed)
        with pytest.raises((ValueError, UnicodeError)):
            dashboard_auth.hash_password(invalid)
    assert not dashboard_auth.verify(password, secrets.token_hex(32))


def test_client_and_global_limits_expire_without_extending_on_refusal(monkeypatch):
    now = [0]
    monkeypatch.setattr(dashboard_auth.time, "monotonic", lambda: now[0])
    limiter = dashboard_auth.Attempts()
    for _ in range(dashboard_auth.CLIENT_ATTEMPTS):
        assert limiter.start("one") is not None
    assert limiter.start("one") is None
    for i in range(dashboard_auth.GLOBAL_ATTEMPTS - dashboard_auth.CLIENT_ATTEMPTS):
        assert limiter.start(str(i)) is not None
    assert limiter.start("new") is None
    assert len(limiter.entries) == dashboard_auth.GLOBAL_ATTEMPTS
    now[0] = dashboard_auth.FAILURE_WINDOW - 1
    assert limiter.start("one") is None
    now[0] += 1
    entry = limiter.start("one")
    assert entry is not None
    limiter.success(entry)
    limiter.success(entry)
    assert not limiter.entries


def test_config_masks_hashes_even_when_raw_host_copy_is_loaded():
    value = secrets.token_hex(32)
    cfg = {
        "dashboard": {
            "auth": {
                "users": [{"name": "owner", "role": "admin", "password_hash": value}],
                "metrics_password_hash": value,
            }
        }
    }
    result = control_service.mask_secrets(cfg)
    auth = result["dashboard"]["auth"]
    assert auth["users"][0] == {
        "name": "owner",
        "role": "admin",
        "password_hash": {"__secret__": True},
    }
    assert auth["metrics_password_hash"] == {"__secret__": True}
    assert value not in json.dumps(result)


async def test_audited_role_change_is_not_misreported_as_an_external_edit(
    tmp_path, monkeypatch, state_manager
):
    path, audit = tmp_path / "config.json", tmp_path / "control.log"
    data = {"dashboard": {"auth": {"users": [{"name": "observer", "role": "viewer"}]}}}
    path.write_text(json.dumps(data))
    monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", str(path))
    monkeypatch.setattr(control_service.config, "CONTROL_AUDIT_LOG", str(audit))
    monkeypatch.setattr(control_service.config, "DASHBOARD_CONTROL_ENABLED", True)
    service = DataService(state_manager, MagicMock(), MagicMock())
    await service._watch_host_config()
    data["dashboard"]["auth"]["users"][0]["role"] = "admin"
    path.write_text(json.dumps(data))
    audit.write_text(
        json.dumps(
            {
                "ts": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "id": str(uuid.uuid4()),
                "actor": "owner",
                "action": "commit",
                "status": "applied",
                "keys": "DASHBOARD_AUTH_CONFIG_FP",
            }
        )
        + "\n"
    )
    await service._watch_host_config()
    assert state_manager.get_audit_events() == []
