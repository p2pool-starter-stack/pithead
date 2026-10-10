"""Seed through the inspected old-image writer, then independently verify persistence and metadata."""

import json
import os
import sqlite3
import stat


def seed_release(path, manager_factory):
    before = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode):
        raise ValueError("the existing dashboard database is not a regular file")
    manager = manager_factory(db_path=path)
    try:
        snapshot = manager.load_snapshot()
        if not isinstance(snapshot, dict) or not snapshot:
            raise ValueError("the old dashboard has no existing snapshot")
        snapshot["miner_released"] = True
        manager.save_snapshot(snapshot)
    finally:
        manager.close()
    with sqlite3.connect("file:" + path + "?mode=ro", uri=True) as db:
        row = db.execute(
            "SELECT value FROM kv_store WHERE key = ?", ("snapshot_latest_data",)
        ).fetchone()
    if not row or json.loads(row[0]) != snapshot:
        raise ValueError("the old writer did not persist the seeded snapshot")
    after = os.stat(path, follow_symlinks=False)
    if (before.st_uid, before.st_gid, before.st_mode, before.st_ino) != (
        after.st_uid,
        after.st_gid,
        after.st_mode,
        after.st_ino,
    ):
        raise ValueError("seeding changed database ownership, mode or identity")


def main():
    from mining_dashboard.config.config import DB_FILE_PATH
    from mining_dashboard.service.storage_service import StateManager

    metadata = os.stat(DB_FILE_PATH, follow_symlinks=False)
    if (os.geteuid(), os.getegid(), metadata.st_uid, metadata.st_gid) != (1000, 1000, 1000, 1000):
        raise ValueError("the old dashboard writer and database must retain their runtime identity")
    seed_release(DB_FILE_PATH, StateManager)
    print(
        "old-image persisted mining release seeded and independently verified; owner and mode preserved"
    )


if __name__ == "__main__":
    main()
