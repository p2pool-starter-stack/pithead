from mining_dashboard.service.network.egress import LOCAL


def _component(posture, name):
    return next(c for c in posture["components"] if c["name"] == name)


def test_caddy_is_not_reported_firewalled(_posture):
    assert _component(_posture(), "caddy") == {
        "name": "caddy",
        "firewalled": False,
        "conns": [{"to": "TLS (internal CA, no ACME)", "route": LOCAL}],
    }


def test_host_networked_services_are_never_reported_firewalled(_posture):
    for knobs in ({}, {"firewall": False}, {"p2pool_clearnet": True, "xvb_tor": False}):
        components = {c["name"]: c for c in _posture(**knobs)["components"]}
        assert {"caddy", "dashboard"} <= set(components), knobs
        for name in ("caddy", "dashboard"):
            assert components[name]["firewalled"] is False, (knobs, name)
