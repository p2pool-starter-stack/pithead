"""Seed and verify the carried mining latch while the disposable guest dashboard is stopped."""

import json
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as db:
    row = db.execute(
        "SELECT value FROM kv_store WHERE key = ?", ("snapshot_latest_data",)
    ).fetchone()
    if not row:
        raise RuntimeError("the established dashboard has no persisted snapshot")
    snapshot = json.loads(row[0])
    snapshot["miner_released"] = True
    db.execute(
        "UPDATE kv_store SET value = ? WHERE key = ?",
        (json.dumps(snapshot), "snapshot_latest_data"),
    )
    stored = db.execute(
        "SELECT value FROM kv_store WHERE key = ?", ("snapshot_latest_data",)
    ).fetchone()
    if json.loads(stored[0])["miner_released"] is not True:
        raise RuntimeError("the mining-release latch was not persisted")
print("persisted mining release verified")
