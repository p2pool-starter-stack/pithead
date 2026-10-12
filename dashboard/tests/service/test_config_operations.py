import json
from pathlib import Path

import pytest

from mining_dashboard.service import config_operations, control_service


@pytest.fixture
def config_paths(tmp_path, monkeypatch):
    live = {
        "monero": {"wallet_address": "4live", "view_key": "", "node_password": ""},
        "workers": {"api_token": ""},
        "dashboard": {"auth": {"password": ""}, "host": "box"},
    }
    reference = {
        **live,
        "monero": {**live["monero"], "prune": True},
        "p2pool": {"pool": "mini", "clearnet": False},
        # telegram.enabled is the approval-tier leaf (2026-09-13 perimeter audit); without one in this synthetic schema
        # the classification tests below cannot tell a NARROWED tier from an EMPTY one.
        "telegram": {
            "enabled": True,
            "events": {"wallet_changed": True, "clearnet_exposed": True},
        },
        "network": {"tor_egress_firewall": True},
        "dashboard": {"auth": {"password": ""}, "host": "box", "control": {"enabled": True}},
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


def test_omitted_array_defaults_are_reported_as_default_keys(tmp_path):
    """#3355: arrays absent from a sparse host config are defaults too, present ones are not."""
    reference = {
        "workers": {"api_port": 8080, "list": []},
        "notifications": {"webhooks": [], "tor": True},
    }
    host = {"workers": {"list": [{"name": "rig"}]}}
    assert config_operations.missing_default_paths(reference, host, control_service._get) == [
        "workers.api_port",
        "notifications.webhooks",
        "notifications.tor",
    ]
    assert list(config_operations.leaf_paths(reference)) == [
        "workers.api_port",
        "notifications.tor",
    ]


def test_real_reference_array_defaults_are_default_keys_for_a_minimal_host(tmp_path, monkeypatch):
    """#3355: a minimal host omitting workers/notifications reports their arrays as defaults."""
    # The repo checkout ("Dashboard tests" job) always has the real file; the dashboard-only image's
    # test stage builds from dashboard/ alone, like test_env_key_perimeter's pithead lookup.
    here = Path(__file__).resolve()
    reference = next(
        (
            p / "config.reference.json"
            for p in here.parents
            if (p / "config.reference.json").is_file()
        ),
        None,
    )
    if reference is None:
        pytest.skip("config.reference.json not present in this test context (dashboard-only image)")
    host = tmp_path / "config.json"
    host.write_text(json.dumps({"dashboard": {"energy": {"cost_per_kwh": 0.1}}}))
    monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", str(host))
    monkeypatch.setattr(control_service.config, "HOST_REFERENCE_PATH", str(reference))
    cfg = control_service.read_config()
    assert cfg["workers"]["list"] == [] and cfg["notifications"]["webhooks"] == []
    assert "workers.list" in cfg["_default_keys"]
    assert "notifications.webhooks" in cfg["_default_keys"]
    assert "dashboard.energy.cost_per_kwh" not in cfg["_default_keys"]
    # Every reference leaf outside the host's one key is a default, so a client that strips
    # untouched defaults and prunes empty containers is left with exactly the host document.
    served = {k: v for k, v in cfg.items() if not k.startswith("_")}
    for dotted in cfg["_default_keys"]:
        *parents, leaf = dotted.split(".")
        node = served
        for key in parents:
            node = node[key]
        del node[leaf]

    def prune(node):
        for key in [k for k, v in node.items() if isinstance(v, dict)]:
            prune(node[key])
            if not node[key]:
                del node[key]

    prune(served)
    served.pop("config_version", None)
    assert served == {"dashboard": {"energy": {"cost_per_kwh": 0.1}}}


def test_perimeter_fields_are_confirm_gated(config_paths):
    """Dashboard authentication plus typed confirmation is the ruled perimeter (#1959)."""
    cfg = control_service.read_config()
    for path in (
        "monero.wallet_address",
        "monero.view_key",
        "workers.api_token",
    ):
        assert path not in cfg["_approval_keys"], path
        assert path in cfg["_confirm_keys"], path
        assert path not in cfg["_editable_keys"], path
    # #2367: the owner ruled every config field must be reachable from the panel; the password
    # left the never-approve set and now confirms like any other unlisted leaf.
    assert "dashboard.auth.password" not in cfg["_approval_keys"]
    assert "dashboard.auth.password" not in cfg["_editable_keys"]
    assert "dashboard.auth.password" in cfg["_confirm_keys"]
    for path in ("telegram.events.wallet_changed", "telegram.events.clearnet_exposed"):  # #2367
        assert path in cfg["_confirm_keys"] and path not in cfg["_editable_keys"], path
    assert not any(path.startswith("ssh.") for path in cfg["_confirm_keys"])
    # The node RPC login confirms (#2367/#2333, #2368): never free-commit, never the approval tier.
    for path in ("monero.node_username", "monero.node_password"):
        assert path in cfg["_confirm_keys"], path
        assert path not in cfg["_editable_keys"], path
        assert path not in cfg["_approval_keys"], path
    assert "telegram.enabled" in cfg["_approval_keys"]
    assert "dashboard.host" in cfg["_approval_keys"]


def test_every_reference_leaf_is_intentionally_classified(config_paths):
    """Every scalar leaf is free, confirmed or approval metadata unless physically restricted."""
    cfg = control_service.read_config()
    classes = {
        **{p: "free" for p in cfg["_editable_keys"]},
        **{p: "confirm" for p in cfg["_confirm_keys"]},
        **{p: "approval" for p in cfg["_approval_keys"]},
    }
    assert classes["p2pool.pool"] == "free"
    assert classes["monero.prune"] == "confirm"
    assert classes["telegram.enabled"] == "approval"
    assert classes["monero.wallet_address"] == "confirm"
    assert classes["network.tor_egress_firewall"] == "confirm"
    assert classes["dashboard.control.enabled"] == "confirm"
    assert classes["p2pool.clearnet"] == "confirm"
    assert classes["dashboard.host"] == "approval"
    assert classes["dashboard.auth.password"] == "confirm"
    assert classes["telegram.events.wallet_changed"] == "confirm"
    assert classes["telegram.events.clearnet_exposed"] == "confirm"
    assert not any(p.startswith("ssh.") for p in classes)
