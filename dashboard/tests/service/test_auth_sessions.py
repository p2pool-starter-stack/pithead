import sqlite3

import pytest

from mining_dashboard.service import auth_sessions
from mining_dashboard.service.storage_service import StateManager


class TestSessionLifetimes:
    @pytest.fixture
    def store(self):
        sm = StateManager(db_path=":memory:")
        auth_sessions.create_schema(sm)
        yield sm
        sm.close()

    @pytest.fixture
    def clock(self, monkeypatch):
        now = [1_000_000.0]
        monkeypatch.setattr(auth_sessions.time, "time", lambda: now[0])
        return now

    def test_unremembered_session_expires_after_idle_timeout(self, store, clock):
        token = auth_sessions.issue(store, "admin", "e", False)
        clock[0] += auth_sessions.IDLE_SECONDS - 5
        assert auth_sessions.validate(store, token, "e")[0] == "admin"
        clock[0] += auth_sessions.IDLE_SECONDS - 5
        assert auth_sessions.validate(store, token, "e")[0] == "admin"
        clock[0] += auth_sessions.IDLE_SECONDS + 5
        assert auth_sessions.validate(store, token, "e") is None

    def test_remembered_session_outlives_the_idle_timeout(self, store, clock):
        token = auth_sessions.issue(store, "admin", "e", True)
        clock[0] += auth_sessions.IDLE_SECONDS * 3
        assert auth_sessions.validate(store, token, "e") is not None

    def test_remembered_session_lasts_thirty_days_unused(self, store, clock):
        token = auth_sessions.issue(store, "admin", "e", True)
        clock[0] += 30 * 86400 - 5
        assert auth_sessions.validate(store, token, "e") is not None
        clock[0] += 30 * 86400 + 5
        assert auth_sessions.validate(store, token, "e") is None

    def test_use_slides_the_remembered_window_and_asks_for_a_cookie_refresh(self, store, clock):
        token = auth_sessions.issue(store, "admin", "e", True)
        clock[0] += 20 * 86400
        _, _, refresh = auth_sessions.validate(store, token, "e")
        assert refresh is True
        clock[0] += 20 * 86400
        assert auth_sessions.validate(store, token, "e") is not None

    def test_no_cookie_refresh_within_a_day(self, store, clock):
        token = auth_sessions.issue(store, "admin", "e", True)
        clock[0] += 3600
        assert auth_sessions.validate(store, token, "e")[2] is False

    def test_unremembered_sessions_never_ask_for_a_persistent_cookie(self, store, clock):
        token = auth_sessions.issue(store, "admin", "e", False)
        clock[0] += 2 * 86400 // 8
        assert auth_sessions.validate(store, token, "e")[2] is False

    def test_session_table_is_capped(self, store, clock):
        for _ in range(auth_sessions.MAX_SESSIONS + 5):
            clock[0] += 1
            auth_sessions.issue(store, "admin", "e", False)
        count = store._conn.execute("SELECT COUNT(*) FROM dashboard_sessions").fetchone()[0]
        assert count == auth_sessions.MAX_SESSIONS

    def test_tokens_are_stored_hashed(self, store):
        token = auth_sessions.issue(store, "admin", "e", False)
        ids = [r["id"] for r in store._conn.execute("SELECT id FROM dashboard_sessions")]
        assert token not in ids


class TestFullDataDisk:
    @pytest.fixture
    def store(self):
        sm = StateManager(db_path=":memory:")
        auth_sessions.create_schema(sm)
        yield sm
        sm.close()

    @pytest.fixture
    def clock(self, monkeypatch):
        now = [1_000_000.0]
        monkeypatch.setattr(auth_sessions.time, "time", lambda: now[0])
        return now

    def test_a_failing_touch_write_keeps_the_session_valid(self, store, clock, full_disk):
        token = auth_sessions.issue(store, "admin", "e", False)
        clock[0] += auth_sessions.TOUCH_SECONDS
        full_disk(store)
        assert auth_sessions.validate(store, token, "e")[0] == "admin"
        assert store.is_db_healthy() is False

    def test_a_failing_refresh_write_still_asks_for_a_cookie_refresh(self, store, clock, full_disk):
        token = auth_sessions.issue(store, "admin", "e", True)
        clock[0] += auth_sessions.COOKIE_REFRESH_SECONDS
        full_disk(store)
        username, remember, refresh = auth_sessions.validate(store, token, "e")
        assert (username, remember, refresh) == ("admin", True, True)

    def test_an_expired_session_is_refused_when_the_delete_fails(self, store, clock, full_disk):
        token = auth_sessions.issue(store, "admin", "e", False)
        clock[0] += auth_sessions.IDLE_SECONDS + 1
        full_disk(store, statements=("DELETE",))
        assert auth_sessions.validate(store, token, "e") is None

    def test_an_unknown_token_is_refused_on_a_full_disk(self, store, full_disk):
        full_disk(store)
        assert auth_sessions.validate(store, "x" * 43, "e") is None

    def test_an_unreadable_store_refuses_the_session_instead_of_raising(self, store, full_disk):
        token = auth_sessions.issue(store, "admin", "e", False)
        full_disk(store, statements=("SELECT",))
        assert auth_sessions.validate(store, token, "e") is None
        assert store.is_db_healthy() is False

    def test_revoke_survives_a_full_disk(self, store, full_disk):
        token = auth_sessions.issue(store, "admin", "e", False)
        full_disk(store)
        auth_sessions.revoke(store, token)

    def test_issue_raises_on_a_full_disk_and_flags_the_store(self, store, full_disk):
        full_disk(store)
        with pytest.raises(sqlite3.OperationalError):
            auth_sessions.issue(store, "admin", "e", False)
        assert store.is_db_healthy() is False

    def test_create_schema_survives_a_full_disk(self, store, full_disk):
        full_disk(store, statements=("CREATE",))
        auth_sessions.create_schema(store)
        assert store.is_db_healthy() is False

    def test_create_schema_survives_a_closed_store(self, store, monkeypatch):
        monkeypatch.setattr(store, "_conn", None)
        auth_sessions.create_schema(store)

    def test_a_corrupt_read_recovers_without_wedging_the_store(self, store, full_disk):
        token = auth_sessions.issue(store, "admin", "e", False)
        full_disk(store, statements=("SELECT",), message="database disk image is malformed")
        assert auth_sessions.validate(store, token, "e") is None
        assert auth_sessions.validate(store, token, "e") is None
        assert store._db_lock.acquire(timeout=1)
        store._db_lock.release()
