import json

import pytest

from mining_dashboard.service import config_operations, control_service
from mining_dashboard.service.data_helpers import _diff_config_keys
from mining_dashboard.wizard_config import deep_merge, prepare_config


@pytest.mark.parametrize(
    "stamp,current,newer",
    [
        ("2.1.0", "2.0.0-pre.1+build", True),
        ("2.0.0", "2.0.0", False),
        ("1.9.0", "2.0.0", False),
        (None, "2.0.0", False),
        (17, "2.0.0", False),
        ("bad", "2.0.0", False),
        ("9.9.9", "dev", False),
        ("9" * 5000 + ".0.0", "2.0.0", False),
        ({"x": 1}, "2.0.0", False),
    ],
)
def test_read_version_and_policy(tmp_path, monkeypatch, stamp, current, newer):
    host = {} if stamp is None else {"config_version": stamp}
    live = tmp_path / "config.json"
    reference = tmp_path / "reference.json"
    live.write_text(json.dumps(host))
    reference.write_text(json.dumps({"config_version": "2.0.0", "p2pool": {"pool": "mini"}}))
    monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", str(live))
    monkeypatch.setattr(control_service.config, "HOST_REFERENCE_PATH", str(reference))
    monkeypatch.setenv("PITHEAD_VERSION", current)
    cfg = control_service.read_config()
    assert cfg.get("config_version") == stamp
    assert cfg["_config_version_newer"] is newer
    for key in ("_editable_keys", "_confirm_keys", "_approval_keys", "_default_keys"):
        assert "config_version" not in cfg[key]
    assert "_config_version_newer" not in config_operations.strip_editor_metadata(cfg)


def test_stamp_is_neither_setting_nor_audit_change():
    old = {"config_version": "2.0.0", "p2pool": {"pool": "mini"}}
    new = {"config_version": "2.1.0", "p2pool": {"pool": "main"}}
    assert list(config_operations.leaf_paths(old)) == ["p2pool.pool"]
    assert _diff_config_keys(old, new) == ["p2pool.pool"]
    assert _diff_config_keys({}, {"config_version": "2.0.0"}) == []
    assert _diff_config_keys({"config_version": "2.0.0"}, {}) == []


def test_wizard_discards_stamp_without_removed_notice():
    cfg, changes = prepare_config(
        {"config_version": "9.9.9", "p2pool": {"pool": "mini"}},
        {"config_version": "2.0.0", "p2pool": {"pool": "mini"}},
    )
    assert cfg == {"p2pool": {"pool": "mini"}}
    assert changes == []
    assert deep_merge({"config_version": "2.0.0"}, {"config_version": "2.1.0"}) == {
        "config_version": "2.1.0"
    }


def test_malformed_object_stamp_never_creates_audit_paths():
    assert _diff_config_keys({"config_version": {"x": 1}}, {"config_version": "2.0.0"}) == []
