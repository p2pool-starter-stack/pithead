import json

import pytest

from mining_dashboard.service import config_operations, control_service


@pytest.fixture
def config_paths(tmp_path, monkeypatch):
    live = {
        "monero": {"wallet_address": "4live", "view_key": "", "node_password": ""},
        "workers": {"api_token": ""},
        "dashboard": {"auth": {"password": ""}},
    }
    reference = {
        **live,
        "monero": {**live["monero"], "prune": True},
        "p2pool": {"pool": "mini"},
        # telegram.enabled is the approval-tier leaf (2026-09-13 perimeter audit); without one in this synthetic schema
        # the classification tests below cannot tell a NARROWED tier from an EMPTY one.
        "telegram": {"enabled": True, "events": {"wallet_changed": True}},
        "ssh": {"enabled": False},
    }
    host = tmp_path / "config.json"
    ref = tmp_path / "reference.json"
    host.write_text(json.dumps(live))
    ref.write_text(json.dumps(reference))
    monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", str(host))
    monkeypatch.setattr(control_service.config, "HOST_REFERENCE_PATH", str(ref))


def test_editor_metadata_is_not_a_schema_leaf():
    assert list(
        config_operations.leaf_paths(
            {"_last_apply": {"status": "applied", "id": "abc"}, "p2pool": {"pool": "mini"}}
        )
    ) == ["p2pool.pool"]


def test_perimeter_fields_are_offered_in_no_tier_at_all(config_paths):
    """the 2026-09-13 perimeter audit. These four used to be ``_approval_keys``, and this test used to assert that they were
    -- because the tier was "every leaf not otherwise classified" and they fell into it. Once #2076
    removed the second identity behind that tier, being offered there meant being committable by
    the dashboard container itself, which is what SECURITY.md promises they are not. A field in no
    tier renders disabled: host-only, or a configuration stick on an appliance."""
    cfg = control_service.read_config()
    for path in (
        "monero.wallet_address",
        "monero.view_key",
        "monero.node_password",
        "workers.api_token",
    ):
        assert path not in cfg["_approval_keys"], path
        assert path not in cfg["_confirm_keys"], path
        assert path not in cfg["_editable_keys"], path
    assert "dashboard.auth.password" not in cfg["_approval_keys"]
    assert "dashboard.auth.password" not in cfg["_editable_keys"]
    # Positive control: the tier is narrowed, not emptied. Without this an approval_paths() that
    # returned nothing at all would satisfy every assertion above.
    assert "telegram.enabled" in cfg["_approval_keys"]


def test_every_reference_leaf_is_intentionally_classified(config_paths):
    """A leaf is free, confirm, approval, or host-only -- and host-only is now a real answer for
    most of the schema rather than the empty set it effectively was between #1978 and the 2026-09-13 perimeter audit."""
    cfg = control_service.read_config()
    classes = {
        **{p: "free" for p in cfg["_editable_keys"]},
        **{p: "confirm" for p in cfg["_confirm_keys"]},
        **{p: "approval" for p in cfg["_approval_keys"]},
    }
    assert classes["p2pool.pool"] == "free"
    assert classes["monero.prune"] == "confirm"
    assert classes["telegram.enabled"] == "approval"
    assert "monero.wallet_address" not in classes, "a payout destination is host-only (2026-09-13 perimeter audit)"
    assert "network.tor_egress_firewall" not in classes
    assert "dashboard.control.enabled" not in classes
    assert "dashboard.auth.password" not in classes
    assert "telegram.events.wallet_changed" not in classes
    assert not any(p.startswith("ssh.") for p in classes)
