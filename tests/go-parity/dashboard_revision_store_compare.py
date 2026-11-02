from mining_dashboard.service.storage_service import StateManager

# ruff: noqa: S101


def test_revision_round_trip_uses_native_storage(tmp_path):
    state = StateManager(str(tmp_path / "state.db"))
    try:
        assert state.note_worker_revision("rig.example.com", {"revision": "one"}) is None
        assert state.note_worker_revision("rig.example.com", {"revision": "two"}) == {
            "worker": "rig.example.com",
            "before": "one",
            "after": "two",
        }
        assert state.get_worker_revision_drift("rig.example.com", "two") == {
            "worker": "rig.example.com",
            "before": "one",
            "after": "two",
        }
    finally:
        state.close()
