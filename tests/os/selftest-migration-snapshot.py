"""Exercise the seed against a real database, including suppressed writer failures."""

import importlib.util
import json
import os
import sqlite3
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "seed", Path(__file__).with_name("migration-release-snapshot.py")
)
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)


class Writer:
    """Storage-contract stand-in; the KVM leg uses the inspected RC2 StateManager."""

    def __init__(self, db_path):
        self.path = db_path
        self.db = sqlite3.connect(db_path)
        self.db.execute("PRAGMA journal_mode=WAL")

    def load_snapshot(self):
        row = self.db.execute("SELECT value FROM kv_store").fetchone()
        return json.loads(row[0]) if row else None

    def save_snapshot(self, snapshot):
        self.db.execute("UPDATE kv_store SET value=?", (json.dumps(snapshot),))
        self.db.commit()

    def close(self):
        self.db.close()


class SilentWriter(Writer):
    def save_snapshot(self, snapshot):
        pass


class ModeWriter(Writer):
    def save_snapshot(self, snapshot):
        super().save_snapshot(snapshot)
        os.chmod(self.path, 0o644)


def require(value):
    if not value:
        raise AssertionError("seed contract failed")


def refuses(path, writer=Writer):
    try:
        seed.seed_release(str(path), writer)
    except (ValueError, OSError):
        return
    raise AssertionError("invalid seed was accepted")


with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "snapshot.db"
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE kv_store (key TEXT PRIMARY KEY, value TEXT)")
        db.execute(
            "INSERT INTO kv_store VALUES (?, ?)",
            ("snapshot_latest_data", json.dumps({"miner_released": False, "other": 123})),
        )
    os.chmod(path, 0o600)
    original = path.stat()
    refuses(path, SilentWriter)
    seed.seed_release(str(path), Writer)
    with sqlite3.connect(path) as db:
        require(
            json.loads(db.execute("SELECT value FROM kv_store").fetchone()[0])
            == {"miner_released": True, "other": 123}
        )
    after = path.stat()
    require(
        (after.st_mode, after.st_uid, after.st_gid, after.st_ino)
        == (original.st_mode, original.st_uid, original.st_gid, original.st_ino)
    )
    seed.seed_release(str(path), Writer)  # Repeated seeding preserves other state.
    refuses(path, ModeWriter)
    linked = Path(directory) / "linked.db"
    linked.symlink_to(path)
    refuses(linked)
    for value in [None, [], {}]:
        with sqlite3.connect(path) as db:
            db.execute("UPDATE kv_store SET value=?", (json.dumps(value),))
        refuses(path)
    with sqlite3.connect(path) as db:
        db.execute("DELETE FROM kv_store")
    refuses(path)
print("selftest-migration-snapshot: PASS")
