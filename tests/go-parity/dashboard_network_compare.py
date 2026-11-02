import copy
import json
import os

import dashboard_network_plugin as adapter
import pytest

from mining_dashboard.service.network import topology, topology_graph

# ruff: noqa: S101

pytest_plugins = ["dashboard_network_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)

SAFE = {
    "firewall": True,
    "p2pool_clearnet": False,
    "xvb_enabled": True,
    "xvb_tor": True,
    "monero_clearnet_sync": False,
    "tari_clearnet_sync": False,
    "monero_route": "local",
    "tari_route": "local",
    "tari_enabled": True,
    "healthchecks_enabled": False,
    "telegram_enabled": False,
    "price_feed_enabled": False,
    "notify_sinks_enabled": False,
    "notify_tor": True,
    "notify_sinks_private": False,
    "xvb_standby_source": "",
    "tor_auto_heal": False,
    "tari_explorer": False,
}


def _compare(name, arguments):
    snapshot = json.dumps(arguments, sort_keys=True)
    with adapter.python_operations():
        expected = adapter.ORIGINALS[name](**copy.deepcopy(arguments))
    actual = adapter.NATIVES[name](**copy.deepcopy(arguments))
    assert actual == expected
    assert json.dumps(arguments, sort_keys=True) == snapshot
    return actual


@pytest.mark.parametrize(
    "overrides",
    [
        {},
        {"firewall": False, "p2pool_clearnet": True},
        {"xvb_tor": False, "notify_sinks_enabled": True, "notify_tor": False},
        {"monero_route": "clearnet", "tari_route": "unknown"},
        {"monero_clearnet_sync": True, "tari_clearnet_sync": True},
        {"tari_enabled": False, "xvb_standby_source": "http://192.0.2.7/source"},
    ],
)
def test_posture_matches_reference(overrides):
    _compare("compute_egress_posture", {**SAFE, **overrides})


@pytest.mark.parametrize(
    "overrides",
    [
        {},
        {"local_miner_enabled": True},
        {"tari_enabled": False, "monero_route": "lan"},
        {"firewall": False, "notify_sinks_enabled": True, "notify_tor": False},
    ],
)
def test_topology_matches_reference(overrides):
    _compare("compute_topology", {**SAFE, "local_miner_enabled": False, **overrides})


def test_topology_reuses_exact_posture_summary(monkeypatch):
    summary = {"opaque": object()}
    posture = {"components": [], "summary": summary}
    monkeypatch.setattr(topology, "compute_egress_posture", lambda **_values: posture)
    outcome = topology.compute_topology(**{**SAFE, "local_miner_enabled": False})
    assert outcome["summary"] is summary


def test_nodes_keep_nonrelocatable_identity_and_copy_relocatable_nodes():
    base = topology_graph.TOPOLOGY_NODES
    nodes = topology_graph.topology_nodes(monero_route="lan", tari_route="local")
    by_id = {node["id"]: node for node in nodes}
    originals = {node["id"]: node for node in base}
    assert by_id["dashboard"] is originals["dashboard"]
    assert by_id["monerod"] is not originals["monerod"]
    assert by_id["tari"] is not originals["tari"]


def test_duplicate_and_unknown_nodes_are_selected_by_index():
    base = topology_graph.TOPOLOGY_NODES
    saved = list(base)
    opaque = object()
    try:
        base[:] = [
            {"id": "unknown", "label": opaque, "zone": "host"},
            {"id": "monerod", "label": "first", "zone": "host"},
            {"id": "monerod", "label": "second", "zone": "host"},
            {"id": "tari", "label": "tari", "zone": "host"},
        ]
        nodes = topology_graph.topology_nodes(monero_route="lan", tari_route="local")
        assert nodes[0] is base[0]
        assert nodes[0]["label"] is opaque
        assert [node["label"] for node in nodes[1:3]] == ["first", "second"]
        assert all(node["remote"] is True for node in nodes[1:3])
    finally:
        base[:] = saved
