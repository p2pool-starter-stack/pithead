"""Pure verdicts for fresh persisted mining recovery through the reserved nodes."""

import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "readiness", Path(__file__).with_name("migration-readiness.py")
)
readiness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(readiness)


def require(value):
    if not value:
        raise AssertionError("mining recovery contract failed")


snapshot = {
    "timestamp": 11,
    "miner_released": True,
    "stratum": {"connections": 1, "total_hashes": 3},
}
node = {"status": "OK", "synchronized": True, "height": 10}
options = {"marker": False, "since": 10}
require(readiness.mining_readiness(snapshot, node, **options) == (10, 3))
require(readiness.mining_readiness(snapshot, node, marker=True, since=10) is None)
for key, value in [
    ("miner_released", False),
    ("miner_released", 1),
    ("timestamp", 10),
    ("timestamp", True),
    ("timestamp", float("nan")),
    ("timestamp", float("inf")),
    ("timestamp", "11"),
    ("stratum", None),
    ("stratum", {"connections": 0, "total_hashes": 3}),
    ("stratum", {"connections": 1, "total_hashes": 0}),
    ("stratum", {"connections": 1, "total_hashes": True}),
]:
    require(readiness.mining_readiness(snapshot | {key: value}, node, **options) is None)
for key, value in [("status", "BUSY"), ("synchronized", False), ("height", 0), ("height", True)]:
    require(readiness.mining_readiness(snapshot, node | {key: value}, **options) is None)
require(readiness.mining_readiness(None, node, **options) is None)
require(readiness.mining_readiness(snapshot, None, **options) is None)
print("selftest-migration-readiness: PASS")
