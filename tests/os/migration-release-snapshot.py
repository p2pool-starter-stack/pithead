"""Verify the earned persisted mining release without modifying the existing database."""

import json
import sqlite3
import sys

with sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True) as db:
    row = db.execute(
        "SELECT value FROM kv_store WHERE key = ?", ("snapshot_latest_data",)
    ).fetchone()
    if not row or json.loads(row[0]).get("miner_released") is not True:
        raise RuntimeError("the established dashboard has no earned persisted mining release")
print("persisted mining release verified")
