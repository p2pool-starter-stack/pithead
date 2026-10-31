from mining_dashboard.web.views.views import build_state


def test_host_resources_are_separate_and_reuse_existing_disk_query(_data, _state_mgr):
    manager = _state_mgr(disk_growth=[])
    state = build_state(_data(), manager, "day")
    assert state["host_resources"]["cpu"]["state"] == "unavailable"
    assert state["host_resources"]["capacity_outlook"]["state"] == "unavailable"
    assert "cpu" in state["system"]
    manager.get_disk_growth.assert_called_once_with()


def test_host_resources_keep_original_sample_time(_data, _state_mgr, monkeypatch):
    monkeypatch.setattr("mining_dashboard.service.host_resources.time.time", lambda: 150)
    metadata = {"cpu": {"sampled_at": 140, "value": 25, "reason": None}}
    state = build_state(_data(system={"host_resources": metadata}), _state_mgr(), "day")
    assert state["host_resources"]["cpu"]["sampled_at"] == 140
    assert state["host_resources"]["cpu"]["age_seconds"] == 10
    assert state["host_resources"]["cpu"]["value"] == 25
