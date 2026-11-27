"""The dashboard's hourly Tari explorer fetch, in both privacy views (#2606).

``tari_health`` fetches ``tari.explorer_url`` through ``TOR_SOCKS_PROXY`` once an hour while the
Tari node is on (#2464), so the egress list and the topology diagram both have to name it. Its own
module because ``test_egress.py`` is at its file-budget ceiling.
"""

import itertools

from mining_dashboard.service.health import tari_health
from mining_dashboard.service.network import egress, topology
from mining_dashboard.service.network.egress import CLEARNET, INACTIVE, TOR

_ROW = "Tari explorer reference"


def _conn(posture):
    dashboard = next(c for c in posture["components"] if c["name"] == "dashboard")
    return next(c for c in dashboard["conns"] if c["to"] == _ROW)


def _edge_of(topo):
    return next(e for e in topo["edges"] if e["label"] == _ROW)


def test_the_reference_rides_tor_when_a_url_is_set_and_tari_is_on(_posture, _topo):
    assert _conn(_posture(tari_explorer=True))["route"] == TOR
    edge = _edge_of(_topo(tari_explorer=True))
    assert (edge["from"], edge["to"], edge["route"], edge["kind"]) == (
        "dashboard",
        "tor",
        TOR,
        "egress",
    )


def test_the_reference_is_inactive_without_a_url_or_with_tari_off(_posture, _topo):
    for knobs in ({}, {"tari_explorer": False}, {"tari_explorer": True, "tari_enabled": False}):
        assert _conn(_posture(**knobs))["route"] == INACTIVE, knobs
        assert _edge_of(_topo(**knobs))["route"] == INACTIVE, knobs


def test_the_reference_never_leaks_and_the_views_agree(_posture, _topo):
    for explorer, firewall, tari_enabled in itertools.product((False, True), repeat=3):
        knobs = {"tari_explorer": explorer, "firewall": firewall, "tari_enabled": tari_enabled}
        posture = _posture(**knobs)
        assert _conn(posture)["route"] != CLEARNET, knobs
        assert _conn(posture)["route"] == _edge_of(_topo(**knobs))["route"], knobs
        flipped = _posture(**{**knobs, "tari_explorer": not explorer})
        assert posture["summary"] == flipped["summary"], knobs


def test_the_live_builders_read_the_monitors_url_and_the_tari_mode(monkeypatch):
    # The knob must be the value tari_health fetches, or the panel disagrees with the fetch.
    for url, mode, route in (
        ("https://x.example/?json", "local", TOR),
        ("https://x.example/?json", "remote", TOR),
        ("https://x.example/?json", "off", INACTIVE),
        ("", "local", INACTIVE),
    ):
        monkeypatch.setattr(tari_health, "TARI_EXPLORER_URL", url)
        monkeypatch.setattr(egress.config, "TARI_MODE", mode)
        assert _conn(egress.egress_posture_from_config())["route"] == route, (url, mode)
        assert _edge_of(topology.topology_from_config())["route"] == route, (url, mode)
