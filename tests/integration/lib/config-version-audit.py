"""Check durable audit key names without exposing any row or requiring the control API."""

import sqlite3
import sys
from pathlib import Path


def stamp_recorded(conn):
    return any(
        key == "config_version" or key.startswith("config_version.")
        for (keys,) in conn.execute("SELECT keys FROM audit_events")
        for key in (keys or "").split()
    )


if __name__ == "__main__":
    # Read-only also fails when the DB is absent, rather than creating an empty proof file.
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "/data/mining_data.db")
    with sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True) as conn:
        print("stamp-recorded" if stamp_recorded(conn) else "clean")
