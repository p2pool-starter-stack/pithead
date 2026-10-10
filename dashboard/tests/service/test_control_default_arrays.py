import json

from mining_dashboard.service import control_service


def test_missing_default_arrays_are_named_for_sparse_editor_round_trips(tmp_path, monkeypatch):
    host_path = tmp_path / "config.json"
    host_path.write_text(json.dumps({"dashboard": {"energy": {"cost_per_kwh": 0.17}}}))
    reference_path = tmp_path / "config.reference.json"
    reference_path.write_text(
        json.dumps(
            {
                "workers": {"list": []},
                "notifications": {"webhooks": []},
                "dashboard": {"energy": {"cost_per_kwh": 0}},
            }
        )
    )
    monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", str(host_path))
    monkeypatch.setattr(control_service.config, "HOST_REFERENCE_PATH", str(reference_path))
    monkeypatch.setattr(control_service.config, "HOST_CORE_KEYS_PATH", str(tmp_path / "missing"))

    cfg = control_service.read_config()

    assert cfg["workers"]["list"] == []
    assert cfg["notifications"]["webhooks"] == []
    assert "workers.list" in cfg["_default_keys"]
    assert "notifications.webhooks" in cfg["_default_keys"]
