"""Emit compact row-identity evidence for durable dashboard history and settings."""

# Table and column names below are closed constants, never input.
# ruff: noqa: S608

import hashlib
import json
import sqlite3
import sys
import time

PERMANENT = ("blocks", "payouts", "disk_growth", "worker_config", "raffle_wins")
# audit_events is pruned at 30 days on an ISO-text ts (#2393); rows it cannot date are never pruned.
AUDIT_TS_SHAPE = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z"
RETAINED = {
    "history": ("timestamp", 30 * 86400),
    "shares": ("ts", 30 * 86400),
    "events": ("ts", 30 * 86400),
    "share_stats": ("ts", 30 * 86400),
    "xvb_history": ("ts", 30 * 86400),
    "network_history": ("ts", 90 * 86400),
    "worker_history": ("ts", 30 * 86400),
}


def row_bytes(row):
    return json.dumps(list(row), separators=(",", ":"), sort_keys=True).encode()


def value_shape(raw):
    """Keep JSON/scalar schema while ignoring expected-to-move telemetry values."""
    try:
        value = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        value = raw
    if isinstance(value, dict):
        return {key: value_shape(json.dumps(value[key])) for key in sorted(value)}
    if isinstance(value, list):
        return [value_shape(json.dumps(item)) for item in value]
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    return "string"


def snapshot(conn, epoch, require_current=False):
    have = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    required = set(PERMANENT) | set(RETAINED) | {"audit_events", "kv_store"}
    if require_current:
        # This table stores the latest live rig observation, so require its schema but do not
        # compare its mutable rows across a dashboard restart.
        required.add("worker_config_revision")
    if not required <= have:
        raise RuntimeError(f"missing durable tables: {sorted(required - have)}")
    lines = []
    for table in PERMANENT:
        lines.append(f"{table} -")
        lines.extend(
            f"{table} {hashlib.sha256(row_bytes(row)).hexdigest()}"
            for row in conn.execute(f"SELECT * FROM {table}")
        )
    iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))  # noqa: E731
    lines.append("audit_events -")
    lines.extend(
        f"audit_events {hashlib.sha256(row_bytes(row)).hexdigest()}"
        for row in conn.execute(
            "SELECT * FROM audit_events WHERE ts NOT GLOB ? OR (ts >= ? AND ts <= ?)",
            (AUDIT_TS_SHAPE, iso(epoch - 30 * 86400 + 7200), iso(epoch)),
        )
    )
    for table, (time_col, retention) in RETAINED.items():
        rows = sorted(
            row_bytes(row)
            for row in conn.execute(
                f"SELECT * FROM {table} WHERE {time_col} >= ? AND {time_col} <= ?",
                (epoch - retention + 7200, epoch),
            )
        )
        digest = hashlib.sha256(b"\n".join(rows)).hexdigest()
        lines.append(f"{table} {digest}")
    lines.extend(
        f"kv_store-key {hashlib.sha256(row_bytes(row)).hexdigest()}"
        for row in conn.execute("SELECT key FROM kv_store")
    )
    lines.extend(
        f"kv_store-stable {hashlib.sha256(row_bytes(row)).hexdigest()}"
        for row in conn.execute(
            "SELECT key,value FROM kv_store "
            "WHERE key NOT LIKE 'xvb_%' AND key != 'snapshot_latest_data'"
        )
    )
    # The key rides in the category (a code-defined xvb_* or snapshot_latest_data name, never a
    # value), so a lost line names which volatile key changed shape (#2057, job 1213).
    lines.extend(
        f"kv_store-volatile-shape:{key} {hashlib.sha256(row_bytes((key, value_shape(value)))).hexdigest()}"
        for key, value in conn.execute(
            "SELECT key,value FROM kv_store WHERE key LIKE 'xvb_%' OR key = 'snapshot_latest_data'"
        )
    )
    return "\n".join(lines)


if sys.argv[1:] == ["--self-test"]:
    db = sqlite3.connect(":memory:")
    for table in PERMANENT:
        db.execute(f"CREATE TABLE {table} (ts REAL, value TEXT)")  # noqa: S608
    for table, (time_col, _) in RETAINED.items():
        db.execute(f"CREATE TABLE {table} ({time_col} REAL, value TEXT)")  # noqa: S608
    db.execute("CREATE TABLE kv_store (key TEXT, value TEXT)")
    db.execute("CREATE TABLE audit_events (id TEXT, ts TEXT)")
    db.execute("INSERT INTO audit_events VALUES ('aged', '1970-01-01T00:00:00Z')")
    db.execute("INSERT INTO audit_events VALUES ('recent', '1970-01-31T00:00:00Z')")
    db.execute("INSERT INTO audit_events VALUES ('undatable', '')")
    db.execute("INSERT INTO blocks VALUES (100, 'kept')")
    db.execute("INSERT INTO history VALUES (100, 'kept')")
    db.execute("INSERT INTO kv_store VALUES ('payout_wallet', 'stable')")
    db.execute("INSERT INTO kv_store VALUES ('xvb_last_update', '100')")
    before = snapshot(db, 31 * 86400)
    db.execute("DELETE FROM audit_events WHERE id='aged'")
    if not set(before.splitlines()) <= set(snapshot(db, 31 * 86400).splitlines()):
        raise RuntimeError("an audit row pruned past its 30-day retention was reported as lost")
    for lost in ("recent", "undatable"):
        db.execute("SAVEPOINT audit")
        db.execute("DELETE FROM audit_events WHERE id=?", (lost,))
        if set(before.splitlines()) <= set(snapshot(db, 31 * 86400).splitlines()):
            raise RuntimeError(f"a lost {lost} audit row was accepted")
        db.execute("ROLLBACK TO audit")
        db.execute("RELEASE audit")
    before = snapshot(db, 100)
    try:
        snapshot(db, 100, require_current=True)
    except RuntimeError:
        pass
    else:
        raise RuntimeError("candidate-only schema was accepted as current before migration")
    db.execute(
        "CREATE TABLE worker_config_revision (worker TEXT, revision TEXT, last_change_id TEXT, ts REAL, drift_from TEXT)"
    )
    db.execute("INSERT INTO worker_config_revision VALUES ('rig', 'first', NULL, 100, NULL)")
    current = snapshot(db, 100, require_current=True)
    db.execute("UPDATE worker_config_revision SET revision='later', ts=101")
    if current != snapshot(db, 100, require_current=True):
        raise RuntimeError("live worker revision observations were treated as durable rows")
    db.execute("INSERT INTO blocks VALUES (101, 'added')")
    db.execute("INSERT INTO history VALUES (101, 'added')")
    db.execute("UPDATE kv_store SET value='101' WHERE key='xvb_last_update'")
    after = snapshot(db, 100)
    if not set(before.splitlines()) <= set(after.splitlines()):
        raise RuntimeError("preserved rows disappeared from the snapshot")
    db.execute("UPDATE kv_store SET value='corrupt' WHERE key='payout_wallet'")
    if set(before.splitlines()) <= set(snapshot(db, 100).splitlines()):
        raise RuntimeError("stable kv_store corruption was accepted")
    db.execute("UPDATE kv_store SET value='not-a-number' WHERE key='xvb_last_update'")
    if set(after.splitlines()) <= set(snapshot(db, 100).splitlines()):
        raise RuntimeError("volatile kv_store schema corruption was accepted")
    raise SystemExit(0)

args = sys.argv[1:]
require_current = args[:1] == ["--require-current-schema"]
if require_current:
    args.pop(0)
print(
    snapshot(
        sqlite3.connect(args[1] if len(args) > 1 else "/data/mining_data.db"),
        int(args[0]),
        require_current,
    )
)
