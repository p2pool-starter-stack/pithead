from mining_dashboard.service.network import egress


def test_local_miner_node_and_edge_follow_the_live_config(_topo, _edge, monkeypatch):
    off = _topo(local_miner_enabled=False)
    assert "local-miner" not in {n["id"] for n in off["nodes"]}
    assert not any(edge["from"] == "local-miner" for edge in off["edges"])

    on = _topo(local_miner_enabled=True)
    node = next(n for n in on["nodes"] if n["id"] == "local-miner")
    assert node == {"id": "local-miner", "label": "Built-in miner", "zone": "host"}
    local = _edge(on, "local-miner", "xmrig-proxy")
    assert (local["route"], local["kind"], local["label"]) == ("local", "ingress", "local stratum")
    assert _edge(on, "rigs", "xmrig-proxy")["route"] == "incoming"

    monkeypatch.setattr(egress.config, "local_miner_enabled", lambda: True)
    assert "local-miner" in {n["id"] for n in egress.topology_from_config()["nodes"]}
