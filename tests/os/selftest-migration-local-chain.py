"""Pure fixture and daemon-verdict negative controls; no source node or guest is touched."""

import copy
import hashlib
import importlib.util
import json
import os
import tempfile
from pathlib import Path
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require(condition):
    if not condition:
        raise AssertionError("migration fixture or readiness contract failed")


fixture = load("migration-monero-snapshot")
readiness = load("migration-readiness")
node = {"height": 10, "synchronized": True, "status": "OK"}
snapshot = {
    "timestamp": 200,
    "miner_released": True,
    "stratum": {"connections": 1, "total_hashes": 20},
}
options = {"local": True, "marker": False, "since": 100, "minimum_height": 10}
require(readiness.mining_readiness(snapshot, node, **options) == (10, 20))
for key, value in [("local", False), ("marker", True), ("since", 200), ("minimum_height", 11)]:
    bad = options | {key: value}
    require(readiness.mining_readiness(snapshot, node, **bad) is None)
for key, value in [
    ("timestamp", float("nan")),
    ("timestamp", True),
    ("miner_released", False),
    ("stratum", None),
]:
    require(readiness.mining_readiness(snapshot | {key: value}, node, **options) is None)
for key in ("connections", "total_hashes"):
    for value in (0, -1, True, "20", None):
        bad = copy.deepcopy(snapshot)
        bad["stratum"][key] = value
        require(readiness.mining_readiness(bad, node, **options) is None)
for key, value in [("status", "BUSY"), ("synchronized", False), ("height", True), ("height", 0)]:
    require(readiness.mining_readiness(snapshot, node | {key: value}, **options) is None)
require(readiness.mining_readiness(None, node, **options) is None)
require(readiness.mining_readiness(snapshot, None, **options) is None)


def refuses(call):
    try:
        call()
    except (ValueError, OSError, TypeError):
        return
    raise AssertionError("unsafe fixture was accepted")


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    database = root / "data.mdb"
    database.write_bytes(b"consistent database fixture")
    sha = hashlib.sha256(database.read_bytes()).hexdigest()
    receipt = {"schema": 1, "consistent": True, "height": 10, "sha256": sha}

    def write_receipt(value):
        (root / "snapshot.json").write_text(json.dumps(value))

    write_receipt(receipt)
    require(fixture.validate(root) == (database.stat().st_size, 10, sha))
    for value in [
        [],
        receipt | {"schema": True},
        receipt | {"consistent": False},
        receipt | {"height": 0},
        receipt | {"sha256": "0" * 64},
    ]:
        write_receipt(value)
        refuses(lambda: fixture.validate(root))
    (root / "snapshot.json").write_text(" " * 8193)
    refuses(lambda: fixture.validate(root))
    write_receipt(receipt)
    database.rename(root / "original")
    database.symlink_to(root / "original")
    refuses(lambda: fixture.validate(root))
    database.unlink()
    os.mkfifo(database)
    refuses(lambda: fixture.validate(root))
    database.unlink()
    database.write_bytes(b"")
    write_receipt(receipt | {"sha256": hashlib.sha256(b"").hexdigest()})
    refuses(lambda: fixture.validate(root))
    database.unlink()
    (root / "original").rename(database)
    write_receipt(receipt)
    data = root / "guest"
    data.mkdir()
    target = data / "monero"
    target.mkdir()
    (target / "lmdb").mkdir()
    (target / "lmdb" / "lock.mdb").write_bytes(b"stale guest lock")
    # Tests do not change ownership on the worker; the guest installer must change both
    # LMDB's directory (for lock creation) and the database, before publishing the copy.
    with patch.object(fixture.os, "fchown") as chown:
        refuses(lambda: fixture.install(str(database), str(target), "0" * 64, data_root=str(data)))
        chown.reset_mock()
        fixture.install(str(database), str(target), sha, data_root=str(data))
        require(chown.call_count == 2)
        require(all(call.args[1:] == (1000, 1000) for call in chown.call_args_list))
    installed = target / "lmdb" / "data.mdb"
    require(hashlib.sha256(installed.read_bytes()).hexdigest() == sha)
    require(installed.stat().st_mode & 0o777 == 0o600)
    require(not database.exists())
    require(not (target / "lmdb" / "lock.mdb").exists())
    database.write_bytes(b"consistent database fixture")
    refuses(
        lambda: fixture.install(
            str(database), str(data / ".." / "escape"), sha, data_root=str(data)
        )
    )
    (data / "linked").symlink_to(root, target_is_directory=True)
    refuses(lambda: fixture.install(str(database), str(data / "linked"), sha, data_root=str(data)))
    require(database.exists())
print("selftest-migration-fixture-and-readiness: PASS")
