import builtins

from mining_dashboard import go_egress_status, go_network


def _topology_providers():
    from mining_dashboard.service.network import egress, topology, topology_graph

    values = {
        "nodes": topology_graph.TOPOLOGY_NODES,
        "graph:NODE_ROUTES": topology_graph.NODE_ROUTES,
        "xvb-route": topology._xvb_route,
        "notify-route": topology._notify_route,
        "standby-route": topology._xvb_standby_route,
        "edge": topology.edge,
        "external-node": topology.ext_node,
    }
    values.update(
        {f"graph:{name}": getattr(topology_graph, name) for name in go_network._GRAPH_NAMES}
    )
    for prefix, module in (("egress", egress), ("topology", topology)):
        values.update(
            {
                f"{prefix}:{name}": getattr(module, name)
                for name in go_network._MODULE_ROUTE_NAMES[prefix]
            }
        )
    return values


def test_compute_topology_preserves_summary_and_orders_providers(monkeypatch):
    from mining_dashboard.service.network import topology

    monkeypatch.setattr(go_network, "PROVIDERS", _topology_providers())
    summary = {"label": "safe"}
    posture = {"components": [], "summary": summary}
    nodes = [{"id": "node"}]
    calls = []
    monkeypatch.setattr(
        topology,
        "compute_egress_posture",
        lambda **kwargs: calls.append(("posture", kwargs)) or posture,
    )
    monkeypatch.setattr(
        topology,
        "topology_nodes",
        lambda **kwargs: calls.append(("nodes", kwargs)) or nodes,
    )
    edge = {"from": "a", "to": "b", "route": "tor", "label": "x", "kind": "network"}

    def native(helper, payload):
        calls.append(("native", helper, payload))
        return [edge]

    monkeypatch.setattr(go_network.go_channel, "call", native)
    result = go_network.compute_topology(
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
    assert result == {"nodes": nodes, "edges": [edge], "summary": summary}
    assert result["summary"] is summary
    assert [call[0] for call in calls] == ["posture", "native", "nodes"]
    assert calls[1][2]["stratum_label"].startswith("stratum :")


def test_firewall_state_unreadable_and_invalid_skip_later_work(monkeypatch, tmp_path):
    from mining_dashboard.service.network import egress_status

    monkeypatch.setattr(
        go_egress_status.go_channel, "call", lambda *_a: (_ for _ in ()).throw(AssertionError)
    )
    assert go_egress_status.egress_firewall_state(tmp_path / "missing") == egress_status.UNVERIFIED

    path = tmp_path / "status.json"
    path.write_text('{"rc": 0, "checked_at": 1}')
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
    calls = []
    monkeypatch.setattr(
        go_egress_status.go_channel,
        "call",
        lambda helper, payload: calls.append(payload["operation"]) or False,
    )
    assert go_egress_status.egress_firewall_state(path) == egress_status.UNVERIFIED
    assert calls == ["firewall-status-valid"]


def test_disabled_firewall_returns_builder_identity_without_native(monkeypatch):
    result = {"summary": {"label": "base"}}
    seen = []
    monkeypatch.setattr(
        go_egress_status.go_channel, "call", lambda *_a: (_ for _ in ()).throw(AssertionError)
    )

    def build(**kwargs):
        seen.append(kwargs)
        return result

    assert go_egress_status.with_firewall_state(build, firewall=False, marker=1) is result
    assert seen == [{"firewall": False, "marker": 1}]


def test_network_install_binds_all_public_policies(monkeypatch):
    from mining_dashboard.service.network import egress, topology, topology_graph

    monkeypatch.setattr(go_network, "PROVIDERS", {})
    monkeypatch.setattr(go_network, "REFERENCE_FUNCTIONS", {})
    monkeypatch.setattr(go_network, "COMPAT_FUNCTIONS", {})
    bindings = (
        (egress, "compute_egress_posture"),
        (topology, "compute_topology"),
        (topology, "compute_egress_posture"),
        (topology, "topology_nodes"),
        (topology_graph, "topology_nodes"),
    )
    for module, name in bindings:
        monkeypatch.setattr(module, name, getattr(module, name))
    go_network.install()
    assert egress.compute_egress_posture is go_network.compute_egress_posture
    assert topology.compute_topology is go_network.compute_topology
    assert topology.topology_nodes is go_network.topology_nodes
    assert topology_graph.topology_nodes is go_network.topology_nodes
    assert go_network.PROVIDERS["nodes"] is topology_graph.TOPOLOGY_NODES
    assert set(go_network.COMPAT_FUNCTIONS) == {
        "compute_egress_posture",
        "compute_topology",
        "topology_nodes",
    }


def test_egress_install_binds_status_and_overlay_policies(monkeypatch):
    from mining_dashboard.service.network import egress, egress_status, topology

    monkeypatch.setattr(go_egress_status, "PROVIDERS", {})
    monkeypatch.setattr(go_egress_status, "CONSTANTS", {})
    monkeypatch.setattr(go_egress_status, "REFERENCE_FUNCTIONS", {})
    bindings = (
        (egress_status, "egress_firewall_state"),
        (egress_status, "with_firewall_state"),
        (egress, "with_firewall_state"),
        (topology, "with_firewall_state"),
    )
    for module, name in bindings:
        monkeypatch.setattr(module, name, getattr(module, name))
    go_egress_status.install()
    assert egress_status.egress_firewall_state is go_egress_status.egress_firewall_state
    assert egress_status.with_firewall_state is go_egress_status.with_firewall_state
    assert egress.with_firewall_state is go_egress_status.with_firewall_state
    assert topology.with_firewall_state is go_egress_status.with_firewall_state
    assert go_egress_status.CONSTANTS["ENFORCED"] == egress_status.ENFORCED
    assert go_egress_status.PROVIDERS["loaded"] is egress_status._firewall_status_loaded


def test_network_shape_guards_choose_compatibility(monkeypatch):
    monkeypatch.setattr(go_network, "_graph_constant_reason", lambda: None)
    monkeypatch.setattr(go_network, "_constant_reason", lambda *args: None)
    monkeypatch.setattr(go_network, "_route_values", lambda: {"tor", "local"})
    monkeypatch.setattr(
        go_network, "_compat", lambda name, reason, **kwargs: (name, reason, kwargs)
    )
    from mining_dashboard.service.network import egress

    monkeypatch.setattr(
        go_network,
        "PROVIDERS",
        {
            "xvb-route": egress._xvb_route,
            "notify-route": egress._notify_route,
            "standby-route": egress._xvb_standby_route,
        },
    )
    result = go_network.compute_egress_posture(
        firewall=1,
        p2pool_clearnet=False,
        xvb_enabled=False,
        xvb_tor=True,
        monero_clearnet_sync=False,
        tari_clearnet_sync=False,
        monero_route="tor",
        healthchecks_enabled=True,
        telegram_enabled=False,
    )
    assert result[:2] == ("compute_egress_posture", "boolean-shape")


def test_egress_provider_guards_and_compatibility_delegate_live_functions(monkeypatch):
    from mining_dashboard.service.network import egress_status

    marker = object()
    monkeypatch.setattr(egress_status, "_firewall_status_loaded", lambda status, now: marker)
    monkeypatch.setattr(egress_status, "_firewall_status_result", lambda rc, age: marker)
    monkeypatch.setattr(
        egress_status,
        "_with_firewall_state_resolved",
        lambda build, state, **knobs: marker,
    )
    assert go_egress_status._loaded_compat("reason", {}, 1) is marker
    assert go_egress_status._result_compat("reason", 0, 1) is marker
    assert go_egress_status._resolved_compat("reason", object(), "missing", {}) is marker

    constants = {
        name: getattr(egress_status, name)
        for name in ("CHECK_INTERVAL_S", "_MAX_EPOCH_S", "ENFORCED", "MISSING", "UNVERIFIED")
    }
    constants["_MISSING_RCS"] = set(egress_status._MISSING_RCS)
    constants["_LABELS"] = dict(egress_status._LABELS)
    monkeypatch.setattr(go_egress_status, "CONSTANTS", constants)
    monkeypatch.setattr(egress_status, "CHECK_INTERVAL_S", "bad")
    assert go_egress_status._status_constant_reason(egress_status) == "status-constant"
    monkeypatch.setattr(egress_status, "CHECK_INTERVAL_S", constants["CHECK_INTERVAL_S"])
    monkeypatch.setattr(egress_status, "_LABELS", {"missing": object()})
    assert go_egress_status._plan_constant_reason(egress_status) == "plan-label"


def test_egress_request_and_provider_reason(monkeypatch):
    from mining_dashboard.service.network import egress_status

    seen = {}
    monkeypatch.setattr(
        go_egress_status.go_channel,
        "call",
        lambda helper, payload: seen.update(helper=helper, payload=payload) or True,
    )
    assert go_egress_status._request("firewall-status-valid", rc={}) is True
    assert seen == {
        "helper": "network",
        "payload": {"operation": "firewall-status-valid", "rc": {}},
    }
    monkeypatch.setattr(go_egress_status, "CONSTANTS", {"CHECK_INTERVAL_S": 1})
    monkeypatch.setattr(go_egress_status, "PROVIDERS", {"open": object()})
    assert go_egress_status._loaded_reason(egress_status) == "open-provider"
    monkeypatch.setattr(go_egress_status, "PROVIDERS", {"clock": object()})
    assert go_egress_status._clock_reason(egress_status) == "clock-provider"
