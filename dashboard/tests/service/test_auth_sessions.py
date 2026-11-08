import hashlib
import secrets
import time

import pytest

from mining_dashboard.service import auth_sessions
from mining_dashboard.service.storage_service import StateManager


@pytest.fixture
def user():
    return {"name": "owner", "role": "admin", "password_hash": secrets.token_hex(32)}


def test_sessions_survive_database_restart_and_store_only_token_digest(tmp_path, user):
    path = str(tmp_path / "state.db")
    store = StateManager(path)
    token = auth_sessions.issue(store, user, True)
    row = dict(store._conn.execute("SELECT * FROM dashboard_sessions").fetchone())
    assert row["id"] == hashlib.sha256(token.encode()).hexdigest()
    assert token not in str(row)
    store.close()
    store = StateManager(path)
    try:
        assert auth_sessions.authenticate(store, token, {"owner": user}, True) == user
        assert auth_sessions.authenticate(store, token, {"owner": user}, False) is None
    finally:
        store.close()


@pytest.mark.parametrize(
    "column,age",
    [("touched", auth_sessions.IDLE_SECONDS), ("created", auth_sessions.ABSOLUTE_SECONDS)],
)
def test_idle_and_absolute_expiry_remove_session(state_manager, user, column, age):
    token = auth_sessions.issue(state_manager, user, False)
    queries = {
        "touched": "UPDATE dashboard_sessions SET touched=?",
        "created": "UPDATE dashboard_sessions SET created=?",
    }
    state_manager._conn.execute(queries[column], (time.time() - age - 1,))
    state_manager._conn.commit()
    assert auth_sessions.authenticate(state_manager, token, {"owner": user}, False) is None
    assert state_manager._conn.execute("SELECT COUNT(*) FROM dashboard_sessions").fetchone()[0] == 0


def test_activity_slides_idle_time_but_not_absolute_expiry(state_manager, user):
    token = auth_sessions.issue(state_manager, user, False)
    before = time.time() - 100
    state_manager._conn.execute(
        "UPDATE dashboard_sessions SET created=?, touched=?", (before, before)
    )
    state_manager._conn.commit()
    assert auth_sessions.authenticate(state_manager, token, {"owner": user}, False) == user
    row = state_manager._conn.execute("SELECT * FROM dashboard_sessions").fetchone()
    assert row["created"] == before
    assert row["touched"] > before


@pytest.mark.parametrize("change", ["password_hash", "role", "revision", "name"])
def test_changed_credentials_never_revive_old_sessions(state_manager, user, change):
    token = auth_sessions.issue(state_manager, user, False)
    changed = dict(user, **{change: secrets.token_hex(16)})
    auth_sessions.reconcile(state_manager, {"owner": changed})
    assert auth_sessions.authenticate(state_manager, token, {"owner": user}, False) is None


def test_logout_and_relogin_revoke_previous_id(state_manager, user):
    token = auth_sessions.issue(state_manager, user, False)
    replacement = auth_sessions.issue(state_manager, user, False, previous=token)
    assert token != replacement
    assert auth_sessions.authenticate(state_manager, token, {"owner": user}, False) is None
    auth_sessions.revoke(state_manager, replacement)
    assert auth_sessions.authenticate(state_manager, replacement, {"owner": user}, False) is None


def test_session_table_is_bounded(state_manager, user, monkeypatch):
    monkeypatch.setattr(auth_sessions, "MAX_SESSIONS", 3)
    for _ in range(6):
        auth_sessions.issue(state_manager, user, False)
    assert state_manager._conn.execute("SELECT COUNT(*) FROM dashboard_sessions").fetchone()[0] == 3


def test_absent_and_oversized_session_ids_are_refused(state_manager, user):
    for token in ("", "x" * 129, secrets.token_urlsafe(32)):
        assert auth_sessions.authenticate(state_manager, token, {"owner": user}, False) is None


def test_viewer_logins_never_evict_owner_sessions(state_manager, user, monkeypatch):
    monkeypatch.setattr(auth_sessions, "MAX_SESSIONS", 2)
    owner_token = auth_sessions.issue(state_manager, user, False)
    viewer = dict(user, name="observer", role="viewer")
    for _ in range(4):
        auth_sessions.issue(state_manager, viewer, False)
    assert auth_sessions.authenticate(state_manager, owner_token, {"owner": user}, False) == user
