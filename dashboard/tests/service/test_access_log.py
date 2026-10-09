"""Rotation, retention and hostile input contracts for the access summary."""

import gzip
import json

import pytest

from mining_dashboard.service import access_log, audit_service

NOW = 200000.0


def row(ts=NOW - 1, status=401, **extra):
    return json.dumps({"ts": ts, "status": status, **extra}).encode() + b"\n"


def generation(root, stamp="2026-10-08T04-10-00.000", compressed=True, data=None, reason="-size"):
    suffix = ".gz" if compressed else ""
    path = root / f"access-{stamp}{reason}.log{suffix}"
    data = row() if data is None else data
    path.write_bytes(gzip.compress(data) if compressed else data)
    return path


@pytest.fixture
def active(tmp_path, monkeypatch):
    path = tmp_path / "access.log"
    path.write_bytes(row(status=200))
    monkeypatch.setattr(audit_service.config, "ACCESS_LOG_PATH", str(path))
    return path


@pytest.mark.parametrize("compressed", [True, False])
@pytest.mark.parametrize("reason", ["-size", ""])
def test_failure_survives_rotation_and_old_future_rows_do_not_count(active, compressed, reason):
    active.write_bytes(row() + row(NOW - 86401) + row(NOW + 1))
    before = audit_service.access_summary(now=NOW)
    generation(active.parent, compressed=compressed, data=active.read_bytes(), reason=reason)
    active.write_bytes(row(status=200))
    after = audit_service.access_summary(now=NOW)
    assert before["failures_24h"] == after["failures_24h"] == 1
    assert after["last_failure_ts"] == NOW - 1
    assert after["entries"] == sorted(after["entries"], key=lambda e: e["ts"], reverse=True)


def test_two_newest_allowlisted_unique_generations_only(active):
    for day in range(1, 5):
        generation(active.parent, stamp=f"2026-10-0{day}T04-10-00.000")
    generation(active.parent, stamp="2026-10-04T04-10-00.000", compressed=False)
    for name in (
        "access.log.1",
        "access-other.log.gz",
        "control.log",
        "access.log.gz",
        "access-2026-10-04T04-10-00.000-time.log.gz",
        "access-2026-10-04T04-10-00.000-custom.log",
    ):
        (active.parent / name).write_bytes(row())
    assert audit_service.access_summary(now=NOW)["failures_24h"] == 2


def test_mixed_legacy_and_size_names_share_one_timestamp_budget(active):
    generation(active.parent, reason="")
    generation(active.parent, compressed=False)
    generation(active.parent, stamp="2026-10-07T04-10-00.000", reason="")
    generation(active.parent, stamp="2026-10-06T04-10-00.000")
    assert audit_service.access_summary(now=NOW)["failures_24h"] == 2


def test_garbage_missing_and_corrupt_generations_leave_active_available(active, monkeypatch):
    active.write_bytes(b"garbage\n[]\n" + row() + b'{"ts": 1')
    bad = generation(active.parent)
    bad.write_bytes(b"not gzip")
    summary = audit_service.access_summary(now=NOW)
    assert summary["available"] is True
    assert summary["failures_24h"] == 1
    bad.unlink()
    missing = generation(active.parent)
    original = access_log._read

    def vanished(path):
        if path == missing:
            path.unlink()
        return original(path)

    monkeypatch.setattr(access_log, "_read", vanished)
    assert audit_service.access_summary(now=NOW)["failures_24h"] == 1


@pytest.mark.parametrize("compressed", [True, False])
def test_oversized_generation_and_active_obey_byte_bounds(active, monkeypatch, compressed):
    monkeypatch.setattr(access_log, "FILE_BYTES", 1024)
    active.write_bytes(b"x" * 2048 + b"\n" + row())
    data = row() + b"x" * 2048 + b"\n" + row(NOW - 2)
    generation(active.parent, compressed=compressed, data=data)
    summary = audit_service.access_summary(now=NOW)
    assert summary["failures_24h"] == 2
    assert {e["ts"] for e in summary["entries"]} == {NOW - 1, NOW - 1 if compressed else NOW - 2}


def test_in_progress_compression_uses_complete_plain_generation(active):
    generation(active.parent, compressed=False)
    partial = generation(active.parent)
    partial.write_bytes(b"\x1f\x8b")
    assert audit_service.access_summary(now=NOW)["failures_24h"] == 1


def test_reads_have_explicit_compressed_and_plain_limits(active, monkeypatch):
    generation(active.parent)
    original = access_log.os.fdopen
    reads = []

    class RecordingFile:
        def __init__(self, stream):
            self.stream = stream

        def __enter__(self):
            return self

        def __exit__(self, *args):
            self.stream.close()

        def __getattr__(self, name):
            return getattr(self.stream, name)

        def read(self, count=-1):
            reads.append(count)
            assert 0 < count <= access_log.FILE_BYTES
            return self.stream.read(count)

    monkeypatch.setattr(access_log.os, "fdopen", lambda *args: RecordingFile(original(*args)))
    assert audit_service.access_summary(now=NOW)["failures_24h"] == 1
    assert reads == [access_log.FILE_BYTES, access_log.FILE_BYTES]


def test_links_and_special_files_are_not_read(active):
    path = generation(active.parent)
    path.unlink()
    path.symlink_to(active)
    assert audit_service.access_summary(now=NOW)["failures_24h"] == 0
    path.unlink()
    access_log.os.mkfifo(path)
    assert audit_service.access_summary(now=NOW)["available"] is True


def test_unreadable_directory_keeps_active_and_missing_active_is_unavailable(active, monkeypatch):
    def denied(_path):
        raise PermissionError

    monkeypatch.setattr(access_log.os, "scandir", denied)
    assert audit_service.access_summary(now=NOW)["available"] is True
    active.unlink()
    assert audit_service.access_summary(now=NOW)["available"] is False


def test_malformed_fields_do_not_break_summary_and_boundary_is_inclusive(active):
    active.write_bytes(
        row(NOW - 86400)
        + row(10**400)
        + row(float("inf"), status=float("inf"), request={"method": []})
        + row(float("nan"), request={"method": {}})
        + b'{"nested":'
        + b"[" * 2000
        + b"0"
        + b"]" * 2000
        + b"}\n"
    )
    summary = audit_service.access_summary(now=NOW)
    assert summary["failures_24h"] == 1
    assert summary["last_failure_ts"] == NOW - 86400
    assert all(e["method"] == "?" for e in summary["entries"])
