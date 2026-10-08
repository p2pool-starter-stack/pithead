"""Bounded local-chain mining verdict from fresh persisted state and direct Monero RPC."""

import json
import math
import os
import sqlite3
import sys


def mining_readiness(snapshot, node, *, local, marker, since, minimum_height):
    """Return height and live hash counter, or None; no UI sync override is accepted."""
    if not isinstance(snapshot, dict) or not isinstance(node, dict):
        return None
    if not local or marker or snapshot.get("miner_released") is not True:
        return None
    timestamp = snapshot.get("timestamp")
    if (
        not isinstance(timestamp, (int, float))
        or isinstance(timestamp, bool)
        or not math.isfinite(timestamp)
        or timestamp <= since
    ):
        return None
    height = node.get("height")
    stratum = snapshot.get("stratum")
    if not isinstance(stratum, dict):
        return None
    workers = stratum.get("connections")
    hashes = stratum.get("total_hashes")
    if any(type(value) is not int or value <= 0 for value in (height, workers, hashes)):
        return None
    if node.get("status") != "OK" or node.get("synchronized") is not True:
        return None
    if height < minimum_height:
        return None
    return height, hashes


def main():
    from mining_dashboard.client.monero.monero_client import MoneroClient
    from mining_dashboard.config.config import DB_FILE_PATH, LOCAL_MONERO_HOST, MONERO_NODE_HOST
    from mining_dashboard.service.data_gates import SYNC_GATE_RESET_PATH

    with sqlite3.connect("file:" + DB_FILE_PATH + "?mode=ro", uri=True, timeout=1) as db:
        row = db.execute(
            "SELECT value FROM kv_store WHERE key = ?", ("snapshot_latest_data",)
        ).fetchone()
    result = mining_readiness(
        json.loads(row[0]) if row else None,
        MoneroClient().get_info(),
        local=MONERO_NODE_HOST == LOCAL_MONERO_HOST,
        marker=os.path.lexists(SYNC_GATE_RESET_PATH),
        since=int(sys.argv[1]),
        minimum_height=int(sys.argv[2]),
    )
    if result is None:
        return 1
    print("ready", *result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
