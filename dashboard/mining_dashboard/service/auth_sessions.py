import hashlib
import secrets
import sqlite3
import time

IDLE_SECONDS = 8 * 3600
REMEMBER_SECONDS = 30 * 86400
COOKIE_REFRESH_SECONDS = 86400
TOUCH_SECONDS = 60
MAX_SESSIONS = 64


def create_schema(store):
    for _ in range(2):
        if store._conn is None:
            return
        try:
            with store._db_lock, store._conn:
                store._conn.execute(
                    "CREATE TABLE IF NOT EXISTS dashboard_sessions "
                    "(id TEXT PRIMARY KEY, username TEXT NOT NULL, epoch TEXT NOT NULL, "
                    "remember INTEGER NOT NULL, created REAL NOT NULL, touched REAL NOT NULL, "
                    "cookie_set REAL NOT NULL)"
                )
            return
        except sqlite3.Error as e:
            store._db_error("Session Schema Error", e)


def _write(store, sql, params):
    try:
        with store._db_lock:
            conn = store._conn
            if conn is None:
                return
            with conn:
                conn.execute(sql, params)
    except sqlite3.Error as e:
        store._db_error("Session Write Error", e)


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
    try:
        with store._db_lock:
            conn = store._conn
            if conn is None:
                raise sqlite3.OperationalError("session store has no connection")
            with conn:
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
    except sqlite3.Error as e:
        store._db_error("Session Write Error", e)
        raise
    return token


def validate(store, token, epoch) -> tuple[str, bool, bool] | None:
    if not token or len(token) > 128 or not epoch:
        return None
    now = time.time()
    try:
        with store._db_lock:
            conn = store._conn
            if conn is None:
                return None
            row = conn.execute(
                "SELECT * FROM dashboard_sessions WHERE id=?", (_digest(token),)
            ).fetchone()
    except sqlite3.Error as e:
        store._db_error("Session Read Error", e)
        return None
    if not row:
        return None
    if row["epoch"] != epoch or row["touched"] <= now - lifetime(row["remember"]):
        _write(store, "DELETE FROM dashboard_sessions WHERE id=?", (row["id"],))
        return None
    refresh = bool(row["remember"]) and now - row["cookie_set"] >= COOKIE_REFRESH_SECONDS
    if now - row["touched"] >= TOUCH_SECONDS or refresh:
        _write(
            store,
            "UPDATE dashboard_sessions SET touched=?, cookie_set=? WHERE id=?",
            (now, now if refresh else row["cookie_set"], row["id"]),
        )
    return row["username"], bool(row["remember"]), refresh


def revoke(store, token):
    _write(store, "DELETE FROM dashboard_sessions WHERE id=?", (_digest(token),))
