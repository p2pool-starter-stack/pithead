"""Selected node sync routes remain visible with the host firewall enabled."""


def _conn(posture, component, needle):
    comp = next(c for c in posture["components"] if c["name"] == component)
    return next(c for c in comp["conns"] if needle in c["to"])


def test_firewall_on_selected_sync_is_shown_as_operator_choice(_posture, _topo, _edge):
    p = _posture(firewall=True, monero_clearnet_sync=True, tari_clearnet_sync=True)
    assert p["summary"]["level"] == "ok"
    assert p["summary"]["all_tor"] is False
    assert (
        "Monero + Tari clearnet first sync or Tor transition pending by your choice"
        in p["summary"]["label"]
    )
    for chain, name in (("monerod", "initial block"), ("tari", "initial sync")):
        conn = _conn(p, chain, name)
        assert conn["chosen_clearnet"] is True
        assert "blocked_by_firewall" not in conn
        edge = _edge(
            _topo(firewall=True, monero_clearnet_sync=True, tari_clearnet_sync=True),
            chain,
            "internet",
        )
        assert edge["chosen_clearnet"] is True
        assert "leak" not in edge
