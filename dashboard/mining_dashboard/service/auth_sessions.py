import hashlib
import secrets
import time

IDLE_SECONDS = 1800
ABSOLUTE_SECONDS = 86400
MAX_SESSIONS = 16


def create_schema(conn):
    conn.execute(
        "CREATE TABLE IF NOT EXISTS dashboard_sessions "
        "(id TEXT PRIMARY KEY, username TEXT NOT NULL, fingerprint TEXT NOT NULL, "
        "created REAL NOT NULL, touched REAL NOT NULL, secure INTEGER NOT NULL)"
    )


def fingerprint(user):
    return hashlib.sha256(
        "\0".join(
            (user["name"], user["role"], user["password_hash"], user.get("revision", ""))
        ).encode()
    ).hexdigest()


def _digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


def _prune(conn, now):
    conn.execute(
        "DELETE FROM dashboard_sessions WHERE created <= ? OR touched <= ?",
        (now - ABSOLUTE_SECONDS, now - IDLE_SECONDS),
    )


def issue(store, user, secure, previous=""):
    token = secrets.token_urlsafe(32)
    now = time.time()
    with store._db_lock, store._conn:
        conn = store._conn
        _prune(conn, now)
        conn.execute("DELETE FROM dashboard_sessions WHERE id=?", (_digest(previous),))
        conn.execute(
            "DELETE FROM dashboard_sessions WHERE id IN "
            "(SELECT id FROM dashboard_sessions WHERE username=? ORDER BY touched DESC LIMIT -1 OFFSET ?)",
            (user["name"], MAX_SESSIONS - 1),
        )
        conn.execute(
            "INSERT INTO dashboard_sessions VALUES (?, ?, ?, ?, ?, ?)",
            (_digest(token), user["name"], fingerprint(user), now, now, int(secure)),
        )
    return token


def authenticate(store, token, users, secure):
    if not token or len(token) > 128:
        return None
    now = time.time()
    with store._db_lock, store._conn:
        conn = store._conn
        _prune(conn, now)
        row = conn.execute(
            "SELECT * FROM dashboard_sessions WHERE id=?", (_digest(token),)
        ).fetchone()
        if not row:
            return None
        user = users.get(row["username"])
        if user is None or row["fingerprint"] != fingerprint(user):
            conn.execute("DELETE FROM dashboard_sessions WHERE id=?", (row["id"],))
            return None
        if row["secure"] and not secure:
            return None
        conn.execute("UPDATE dashboard_sessions SET touched=? WHERE id=?", (now, row["id"]))
        return user


def revoke(store, token):
    with store._db_lock, store._conn:
        store._conn.execute("DELETE FROM dashboard_sessions WHERE id=?", (_digest(token),))


def reconcile(store, users):
    with store._db_lock, store._conn:
        for row in store._conn.execute("SELECT id, username, fingerprint FROM dashboard_sessions"):
            user = users.get(row["username"])
            if user is None or fingerprint(user) != row["fingerprint"]:
                store._conn.execute("DELETE FROM dashboard_sessions WHERE id=?", (row["id"],))
