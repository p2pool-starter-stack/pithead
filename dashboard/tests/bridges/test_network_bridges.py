import json

import pytest

from mining_dashboard import go_egress_status, go_network, go_network_validation

ROUTES = {"tor", "clearnet", "incoming", "local", "lan", "unknown", "inactive"}


def posture():
    return {
        "components": [
            {"name": "pool", "firewalled": True, "conns": [{"to": "node", "route": "tor"}]}
        ],
        "summary": {
            "firewall": True,
            "leaks": 0,
            "blocked_by_firewall": 0,
            "unverified": 0,
            "all_tor": True,
            "level": "ok",
            "label": "Tor only",
        },
    }


def test_utf8_and_network_reply_validation():
    assert go_network_validation.utf8_within("é", 2)
    assert not go_network_validation.utf8_within("é", 1)
    assert not go_network_validation.utf8_within("\ud800", 8)
    value = posture()
    assert go_network_validation.validate_posture(value, ROUTES) is value
    edges = [
        {
            "from": "a",
            "to": "b",
            "route": "tor",
            "label": "link",
            "kind": "network",
            "leak": False,
        }
    ]
    assert go_network_validation.validate_edges(edges, ROUTES) is edges


@pytest.mark.parametrize(
    "value",
    [
        {},
        {"components": [], "summary": {}},
        {
            "components": [{"name": "x", "conns": [{"to": "y", "route": "bad"}]}],
            "summary": posture()["summary"],
        },
    ],
)
def test_posture_validation_rejects_malformed_values(value):
    with pytest.raises(RuntimeError, match="native network"):
        go_network_validation.validate_posture(value, ROUTES)


def test_edges_validation_rejects_unknown_routes_and_flag_types():
    with pytest.raises(RuntimeError, match="invalid edges"):
        go_network_validation.validate_edges(
            [{"from": "a", "to": "b", "route": "bad", "label": "x", "kind": "x"}],
            ROUTES,
        )
    with pytest.raises(RuntimeError, match="invalid edges"):
        go_network_validation.validate_edges(
            [
                {
                    "from": "a",
                    "to": "b",
                    "route": "tor",
                    "label": "x",
                    "kind": "x",
                    "leak": 1,
                }
            ],
            ROUTES,
        )


def test_numeric_projection_and_reply_guards():
    assert go_egress_status._numeric(3) == {"kind": "int", "value": "3"}
    assert go_egress_status._numeric(float("inf")) == {"kind": "float", "value": "inf"}
    assert go_egress_status._numeric(True) == {"kind": "invalid"}
    assert go_egress_status._numeric(1 << 1001) is None
    assert go_egress_status._valid_reply(True) is True
    assert go_egress_status._state_reply("missing") == "missing"
    with pytest.raises(RuntimeError):
        go_egress_status._valid_reply(1)
    with pytest.raises(RuntimeError):
        go_egress_status._state_reply("other")


def test_firewall_plan_overlay_preserves_result_identity(monkeypatch):
    from mining_dashboard.service.network import egress_status

    constants = {
        name: getattr(egress_status, name)
        for name in ("CHECK_INTERVAL_S", "_MAX_EPOCH_S", "ENFORCED", "MISSING", "UNVERIFIED")
    }
    constants["_MISSING_RCS"] = set(egress_status._MISSING_RCS)
    constants["_LABELS"] = dict(egress_status._LABELS)
    monkeypatch.setattr(go_egress_status, "CONSTANTS", constants)
    monkeypatch.setattr(
        go_egress_status,
        "PROVIDERS",
        {
            "resolved": egress_status._with_firewall_state_resolved,
            "clock": egress_status.time.time,
        },
    )
    monkeypatch.setattr(
        go_egress_status.go_channel,
        "call",
        lambda helper, payload: {
            "firewall": False,
            "overlay": True,
            "warn": True,
            "prefix": constants["_LABELS"]["missing"],
        },
    )
    result = {"summary": {"level": "ok", "label": "base"}}
    assert (
        go_egress_status.with_firewall_state(
            lambda **kwargs: result, firewall=True, state="missing", sample=1
        )
        is result
    )
    assert result["summary"]["firewall_state"] == "missing"
    assert result["summary"]["level"] == "warn"
    assert result["summary"]["label"].endswith("; base")


def test_firewall_plan_rejects_inconsistent_reply(monkeypatch):
    monkeypatch.setattr(go_egress_status, "CONSTANTS", {"_LABELS": {"missing": "Missing"}})
    with pytest.raises(RuntimeError, match="inconsistent"):
        go_egress_status._plan_reply(
            {"firewall": True, "overlay": True, "warn": True, "prefix": "Missing"},
            "missing",
        )


def test_firewall_state_reads_once_and_uses_two_native_decisions(monkeypatch, tmp_path):
    import builtins

    from mining_dashboard.service.network import egress_status

    path = tmp_path / "status.json"
    path.write_text(json.dumps({"rc": 0, "checked_at": 10}))
    constants = {
        name: getattr(egress_status, name)
        for name in ("CHECK_INTERVAL_S", "_MAX_EPOCH_S", "ENFORCED", "MISSING", "UNVERIFIED")
    }
    constants["_MISSING_RCS"] = set(egress_status._MISSING_RCS)
    constants["_LABELS"] = dict(egress_status._LABELS)
    monkeypatch.setattr(go_egress_status, "CONSTANTS", constants)
    monkeypatch.setattr(
        go_egress_status,
        "PROVIDERS",
        {
            "open": builtins.open,
            "abs": builtins.abs,
            "json-load": egress_status.json.load,
            "clock": egress_status.time.time,
            "loaded": egress_status._firewall_status_loaded,
            "result": egress_status._firewall_status_result,
        },
    )
    operations = []

    def call(_helper, payload):
        operations.append(payload["operation"])
        return True if payload["operation"] == "firewall-status-valid" else "enforced"

    monkeypatch.setattr(go_egress_status.go_channel, "call", call)
    assert go_egress_status.egress_firewall_state(path, now=11) == "enforced"
    assert operations == ["firewall-status-valid", "firewall-status-result"]


def test_compute_egress_posture_sends_canonical_routes(monkeypatch):
    from mining_dashboard.service.network import egress, topology_graph

    providers = {"graph:NODE_ROUTES": topology_graph.NODE_ROUTES}
    providers.update(
        {f"graph:{name}": getattr(topology_graph, name) for name in go_network._GRAPH_NAMES}
    )
    providers.update(
        {
            "xvb-route": egress._xvb_route,
            "notify-route": egress._notify_route,
            "standby-route": egress._xvb_standby_route,
        }
    )
    providers.update(
        {
            f"egress:{name}": getattr(egress, name)
            for name in go_network._MODULE_ROUTE_NAMES["egress"]
        }
    )
    monkeypatch.setattr(go_network, "PROVIDERS", providers)
    seen = {}
    value = posture()
    monkeypatch.setattr(
        go_network.go_channel,
        "call",
        lambda helper, payload: seen.update(helper=helper, payload=payload) or value,
    )
    result = go_network.compute_egress_posture(
        firewall=True,
        p2pool_clearnet=False,
        xvb_enabled=False,
        xvb_tor=True,
        monero_clearnet_sync=False,
        tari_clearnet_sync=False,
        monero_route="tor",
        healthchecks_enabled=True,
        telegram_enabled=False,
    )
    assert result is value
    assert seen["payload"]["operation"] == "posture"
    assert seen["payload"]["monero_route"] == "tor"


def test_topology_nodes_preserves_plain_identity_and_relocates_copies(monkeypatch):
    from mining_dashboard.service.network import topology_graph

    providers = {
        "nodes": topology_graph.TOPOLOGY_NODES,
        "graph:NODE_ROUTES": topology_graph.NODE_ROUTES,
    }
    providers.update(
        {f"graph:{name}": getattr(topology_graph, name) for name in go_network._GRAPH_NAMES}
    )
    monkeypatch.setattr(go_network, "PROVIDERS", providers)
    base = topology_graph.TOPOLOGY_NODES
    expected = [index for index, node in enumerate(base) if node.get("id") != "local-miner"]
    relocatable = []
    for index, node in enumerate(base):
        if index not in expected:
            continue
        if node.get("id") in ("monerod", "tari"):
            relocatable.append({"index": index, "zone": "remote", "remote": True, "route": "tor"})
    seen = {}
    monkeypatch.setattr(
        go_network.go_channel,
        "call",
        lambda helper, payload: (
            seen.update(helper=helper, payload=payload)
            or {"indices": expected, "relocatable": relocatable}
        ),
    )
    result = go_network.topology_nodes(monero_route="tor", tari_route="tor")
    assert seen["helper"] == "network"
    assert all(set(node) == {"id", "zone"} for node in seen["payload"]["nodes"])
    for result_index, index in enumerate(expected):
        node = base[index]
        if node.get("id") in ("monerod", "tari"):
            assert result[result_index] is not node
            assert result[result_index]["remote"] is True
        else:
            assert result[result_index] is node


def test_topology_nodes_rejects_incomplete_plan(monkeypatch):
    from mining_dashboard.service.network import topology_graph

    providers = {
        "nodes": topology_graph.TOPOLOGY_NODES,
        "graph:NODE_ROUTES": topology_graph.NODE_ROUTES,
    }
    providers.update(
        {f"graph:{name}": getattr(topology_graph, name) for name in go_network._GRAPH_NAMES}
    )
    monkeypatch.setattr(go_network, "PROVIDERS", providers)
    monkeypatch.setattr(
        go_network.go_channel,
        "call",
        lambda *_a: {
            "indices": [
                index
                for index, node in enumerate(topology_graph.TOPOLOGY_NODES)
                if node.get("id") != "local-miner"
            ],
            "relocatable": [],
        },
    )
    with pytest.raises(RuntimeError, match="incomplete node metadata"):
        go_network.topology_nodes(monero_route="tor", tari_route="tor")


def test_node_request_budget_uses_reference_compatibility(monkeypatch):
    monkeypatch.setattr(go_network, "_NATIVE_MAX_REQUEST_BYTES", 1)
    monkeypatch.setattr(go_network, "_graph_constant_reason", lambda: None)
    monkeypatch.setattr(go_network, "_route_values", lambda: ROUTES)
    monkeypatch.setitem(go_network.PROVIDERS, "nodes", [{"id": "x", "zone": "local"}])
    monkeypatch.setattr(
        go_network,
        "_compat",
        lambda name, reason, **kwargs: (name, reason, kwargs),
    )
    from mining_dashboard.service.network import topology_graph

    monkeypatch.setattr(topology_graph, "TOPOLOGY_NODES", go_network.PROVIDERS["nodes"])
    name, reason, _ = go_network.topology_nodes(monero_route="tor", tari_route="tor")
    assert (name, reason) == ("topology_nodes", "node-request-size")
