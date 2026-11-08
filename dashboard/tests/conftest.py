"""Shared pytest fixtures for the mining_dashboard test suite.

Everything here keeps tests hermetic: no real database on disk, no network, no containers.
"""

import pytest

from mining_dashboard.service.storage_service import StateManager


@pytest.fixture(autouse=True)
def _isolate_db(tmp_path, monkeypatch):
    """Safety net: any StateManager() built without an explicit path uses a throwaway temp
    file instead of the production /data location."""
    db_file = str(tmp_path / "test.db")
    monkeypatch.setattr(
        "mining_dashboard.service.storage_service.DB_FILE_PATH", db_file, raising=False
    )


@pytest.fixture(autouse=True)
def _prune_sampler_off(monkeypatch):
    """Pin the stores' probabilistic retention sampler OFF by default (#1814).

    Every ``DELETE FROM`` in the storage mixins is gated on ``random.random() < 0.05`` — the only
    thing ``random.random`` is used for in this package. Fixtures all over the suite stamp FIXED
    calendar timestamps, which age out of their table's retention window as the real clock moves
    past them, so a sampler that happened to fire would delete rows a test had just written and
    fail it at random. Pinning it high makes the whole suite deterministic; a test that is about
    retention re-patches this to 0.0 and asserts the delete."""
    monkeypatch.setattr("random.random", lambda: 1.0)


@pytest.fixture
def state_manager():
    """A real StateManager backed by an in-memory SQLite database."""
    sm = StateManager(db_path=":memory:")
    yield sm
    sm.close()
