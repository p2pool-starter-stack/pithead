import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603

ROOT = Path(__file__).resolve().parents[2]


def _run(script, directory, implementation="python"):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL=implementation,
        PYTHONPATH=str(ROOT / "dashboard"),
        WIZARD_SPOOL=str(directory / "spool"),
        WIZARD_RESTORE=str(directory / "restore"),
        PITHEAD_DASHBOARD_GO_BINARY=str(ROOT / "go/bin/dashboard"),
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def _paired(tmp_path, script):
    expected = _run(script, tmp_path / "reference")
    actual = _run(script, tmp_path / "native", "go")
    assert actual == expected
    return actual


def test_atomic_writes_match_bytes_modes_overwrite_and_umask(tmp_path):
    result = _paired(
        tmp_path,
        r"""
import json, os
from pathlib import Path
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_transaction import install
    install(None)
from mining_dashboard import wizard_transaction as transaction
spool = Path(os.environ["WIZARD_SPOOL"])
os.umask(0o027)
transaction.spool_write("text", "été\n", str(spool / "nested"))
transaction.spool_write("blob", b"\x00\xfffirst")
transaction.spool_write("blob", b"\x10replacement")
files = {
    str(path.relative_to(spool)): {
        "hex": path.read_bytes().hex(),
        "mode": path.stat().st_mode & 0o777,
    }
    for path in spool.rglob("*") if path.is_file()
}
print(json.dumps({
    "files": files,
    "nested_mode": (spool / "nested").stat().st_mode & 0o777,
    "temps": sorted(path.name for path in spool.rglob(".*")),
}))
""",
    )
    assert result == {
        "files": {
            "blob": {"hex": "107265706c6163656d656e74", "mode": 0o600},
            "nested/text": {"hex": "c3a974c3a90a", "mode": 0o600},
        },
        "nested_mode": 0o750,
        "temps": [],
    }


def test_maximum_restore_archive_matches_without_transport_expansion(tmp_path):
    result = _paired(
        tmp_path,
        r"""
import hashlib, json, os
from pathlib import Path
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_transaction import install
    install(None)
from mining_dashboard import wizard_transaction as transaction
data = b"0123456789abcdef" * (4 * 1024 * 1024)
transaction.spool_write("restore-archive", data)
path = Path(os.environ["WIZARD_SPOOL"]) / "restore-archive"
print(json.dumps({
    "size": path.stat().st_size,
    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    "temps": [item.name for item in path.parent.glob(".restore-archive.*")],
}))
""",
    )
    assert result == {
        "size": 64 * 1024 * 1024,
        "sha256": "42ef3a50fe506ced865473b082c8b28f6ce254e6e2b01266b6a563531a6267bc",
        "temps": [],
    }


def test_cleanup_matches_exact_ownership_and_symlink_safety(tmp_path):
    result = _paired(
        tmp_path,
        r"""
import json, os
from pathlib import Path
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_transaction import install
    install(None)
from mining_dashboard import wizard_transaction as transaction
spool = Path(os.environ["WIZARD_SPOOL"])
restore = Path(os.environ["WIZARD_RESTORE"])
outside = spool.parent / "outside-secret"
spool.mkdir(parents=True)
restore.mkdir(parents=True)
outside.write_text("keep")
for name in transaction.ROLLBACK_FILES:
    (spool / name).write_text(name)
for name in ("restore-passphrase", "restore-archive"):
    (restore / name).write_text(name)
(spool / "unrelated").write_text("keep")
(restore / "unrelated").write_text("keep")
(spool / ".config.json.crash").write_text("remove")
(restore / ".restore-passphrase.crash").symlink_to(outside)
unsafe = spool / ".last-attempt.json.unsafe"
unsafe.mkdir()
transaction.clear_submission_sidecars()
first = transaction.clear_failed_restore()
snapshot = {
    "first": first,
    "spool": sorted(path.name for path in spool.iterdir()),
    "restore": sorted(path.name for path in restore.iterdir()),
    "outside": outside.read_text(),
}
unsafe.rmdir()
snapshot["second"] = transaction.clear_page_temps()
print(json.dumps(snapshot))
""",
    )
    assert result == {
        "first": False,
        "spool": [".last-attempt.json.unsafe", "unrelated"],
        "restore": ["unrelated"],
        "outside": "keep",
        "second": True,
    }


@pytest.mark.parametrize(
    ("seed", "status", "message", "remaining"),
    [
        ("restore-archive", 409, "another setup submission is already being processed", True),
        ("restore-inflight", 409, "another setup submission is already being processed", True),
        ("installing", 409, "another setup submission is already being processed", True),
        ("orphan-passphrase", None, None, False),
    ],
)
def test_submission_conflicts_and_orphan_cleanup_match(tmp_path, seed, status, message, remaining):
    script = f"""
import json, os
from pathlib import Path
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_transaction import install
    install(None)
from mining_dashboard import wizard_transaction as transaction
spool = Path(os.environ["WIZARD_SPOOL"])
restore = Path(os.environ["WIZARD_RESTORE"])
spool.mkdir(parents=True)
restore.mkdir(parents=True)
seed = {seed!r}
path = restore / "restore-passphrase" if seed == "orphan-passphrase" else spool / seed
path.write_text("value")
if seed == "orphan-passphrase":
    (spool / "install-request").write_text("stale")
response = transaction.submission_conflict()
body = None if response is None else json.loads(response.body)
print(json.dumps({{
    "status": None if response is None else response.status,
    "message": None if body is None else body["error"],
    "remaining": path.exists(),
    "stale": (spool / "install-request").exists(),
}}))
"""
    result = _paired(tmp_path, script)
    assert result == {
        "status": status,
        "message": message,
        "remaining": remaining,
        "stale": False,
    }


def test_missing_native_helper_fails_closed(tmp_path, monkeypatch):
    from mining_dashboard import go_wizard_transaction

    spool = tmp_path / "spool"
    monkeypatch.setenv("WIZARD_SPOOL", str(spool))
    monkeypatch.setenv("WIZARD_RESTORE", str(tmp_path / "restore"))
    monkeypatch.setenv("PITHEAD_DASHBOARD_GO_BINARY", str(tmp_path / "missing"))
    with pytest.raises(OSError, match="writer unavailable"):
        go_wizard_transaction.spool_write("config.json", "secret")
    assert not spool.exists()
