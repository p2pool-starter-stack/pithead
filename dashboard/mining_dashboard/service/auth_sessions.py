import hashlib
import secrets
import time

IDLE_SECONDS = 8 * 3600
REMEMBER_SECONDS = 30 * 86400
COOKIE_REFRESH_SECONDS = 86400
TOUCH_SECONDS = 60
MAX_SESSIONS = 64


def create_schema(store):
    with store._db_lock, store._conn:
        store._conn.execute(
            "CREATE TABLE IF NOT EXISTS dashboard_sessions "
            "(id TEXT PRIMARY KEY, username TEXT NOT NULL, epoch TEXT NOT NULL, "
            "remember INTEGER NOT NULL, created REAL NOT NULL, touched REAL NOT NULL, "
            "cookie_set REAL NOT NULL)"
        )


def _digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


def lifetime(remember):
    return REMEMBER_SECONDS if remember else IDLE_SECONDS


def _prune(conn, now):
    conn.execute(
        "DELETE FROM dashboard_sessions WHERE "
        "(remember = 1 AND touched <= ?) OR (remember = 0 AND touched <= ?)",
        (now - REMEMBER_SECONDS, now - IDLE_SECONDS),
    )


def issue(store, username, epoch, remember):
    token = secrets.token_urlsafe(32)
    now = time.time()
    with store._db_lock, store._conn:
        conn = store._conn
        _prune(conn, now)
        conn.execute("DELETE FROM dashboard_sessions WHERE epoch != ?", (epoch,))
        conn.execute(
            "DELETE FROM dashboard_sessions WHERE id IN "
            "(SELECT id FROM dashboard_sessions ORDER BY touched DESC LIMIT -1 OFFSET ?)",
            (MAX_SESSIONS - 1,),
        )
        conn.execute(
            "INSERT INTO dashboard_sessions VALUES (?, ?, ?, ?, ?, ?, ?)",
            (_digest(token), username, epoch, int(remember), now, now, now),
        )
    return token


def validate(store, token, epoch):
    """Return (username, remember, refresh_cookie) for a live session, else None."""
    if not token or len(token) > 128 or not epoch:
        return None
    now = time.time()
    with store._db_lock, store._conn:
        conn = store._conn
        row = conn.execute(
            "SELECT * FROM dashboard_sessions WHERE id=?", (_digest(token),)
        ).fetchone()
        if not row:
            return None
        if row["epoch"] != epoch or row["touched"] <= now - lifetime(row["remember"]):
            conn.execute("DELETE FROM dashboard_sessions WHERE id=?", (row["id"],))
            return None
        refresh = bool(row["remember"]) and now - row["cookie_set"] >= COOKIE_REFRESH_SECONDS
        if now - row["touched"] >= TOUCH_SECONDS or refresh:
            conn.execute(
                "UPDATE dashboard_sessions SET touched=?, cookie_set=? WHERE id=?",
                (now, now if refresh else row["cookie_set"], row["id"]),
            )
        return row["username"], bool(row["remember"]), refresh


def revoke(store, token):
    with store._db_lock, store._conn:
        store._conn.execute("DELETE FROM dashboard_sessions WHERE id=?", (_digest(token),))
