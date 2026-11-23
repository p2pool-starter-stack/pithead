"""The egress panel and header badge follow the host's live firewall verdict (#2599)."""

import json

import pytest

from mining_dashboard.service.network import egress, egress_status, topology
from mining_dashboard.service.network.egress import compute_egress_posture
from mining_dashboard.service.network.egress_status import (
    ENFORCED,
    MISSING,
    UNVERIFIED,
    egress_firewall_state,
    with_firewall_state,
)
from mining_dashboard.service.network.topology import compute_topology
from mining_dashboard.web.views.views import _egress_badge
from tests.service.conftest import _SAFE

NOW = 1_800_000_000


def _write(tmp_path, body):
    path = tmp_path / "egress-status.json"
    path.write_text(body if isinstance(body, str) else json.dumps(body))
    return str(path)


@pytest.mark.parametrize(
    ("rc", "state"),
    [(0, ENFORCED), (1, MISSING), (2, MISSING), (3, UNVERIFIED), (4, MISSING), (5, MISSING)],
)
def test_each_host_verdict_maps_to_a_state(tmp_path, rc, state):
    path = _write(tmp_path, {"rc": rc, "verdict": "x", "checked_at": NOW - 60})
    assert egress_firewall_state(path, now=NOW) == state


@pytest.mark.parametrize(
    "body",
    [
        None,
        "{not json",
        [],
        {"verdict": "enforced", "checked_at": NOW},
        {"rc": 0, "checked_at": NOW - 3 * 120 - 1},
        {"rc": 0, "checked_at": NOW + 3 * 120 + 1},
        {"rc": 1, "checked_at": NOW - 3 * 120 - 1},
    ],
)
def test_anything_but_a_fresh_verdict_is_unverified(tmp_path, body):
    path = str(tmp_path / "absent.json") if body is None else _write(tmp_path, body)
    assert egress_firewall_state(path, now=NOW) == UNVERIFIED


@pytest.mark.parametrize(
    "body",
    [
        '{"rc": 0, "checked_at": NaN}',
        '{"rc": 0, "checked_at": Infinity}',
        '{"rc": 0, "checked_at": -Infinity}',
        {"rc": False, "checked_at": NOW},
        {"rc": True, "checked_at": NOW},
        {"rc": "0", "checked_at": NOW},
        {"rc": 0.0, "checked_at": NOW},
        {"rc": 0, "checked_at": True},
        {"rc": 0, "checked_at": str(NOW)},
        '{"rc": 0, "checked_at": 1' + "0" * 399 + "}",
        '{"rc": 0, "checked_at": -1' + "0" * 399 + "}",
    ],
)
def test_a_malformed_field_is_unverified_never_enforced(tmp_path, body):
    assert egress_firewall_state(_write(tmp_path, body), now=NOW) == UNVERIFIED


@pytest.mark.parametrize("opener", ["[", '{"rc": '])
def test_deeply_nested_json_cannot_escape_the_reader(tmp_path, opener):
    assert egress_firewall_state(_write(tmp_path, opener * 100_000), now=NOW) == UNVERIFIED


def test_a_check_within_three_intervals_is_fresh(tmp_path):
    path = _write(tmp_path, {"rc": 0, "checked_at": NOW - 3 * 120})
    assert egress_firewall_state(path, now=NOW) == ENFORCED


def _posture(state, **overrides):
    return with_firewall_state(compute_egress_posture, state=state, **{**_SAFE, **overrides})


def test_an_enforced_firewall_keeps_today_s_posture():
    assert _posture(ENFORCED, p2pool_clearnet=True) == {
        **compute_egress_posture(**{**_SAFE, "p2pool_clearnet": True}),
        "summary": {
            **compute_egress_posture(**{**_SAFE, "p2pool_clearnet": True})["summary"],
            "firewall_state": ENFORCED,
        },
    }


def test_a_missing_firewall_warns_and_claims_nothing_is_blocked():
    p = _posture(MISSING, p2pool_clearnet=True)
    s = p["summary"]
    assert s["firewall_state"] == MISSING
    assert s["level"] == "warn"
    assert s["label"].startswith("Tor-only egress firewall MISSING")
    assert "blocked by the egress firewall" not in s["label"]
    assert s["blocked_by_firewall"] == 0
    assert (
        s["leaks"] == 0
    )
    assert not any(c.get("blocked_by_firewall") for comp in p["components"] for c in comp["conns"])
    badge = _egress_badge(s)
    assert badge["variant"] == "warn"
    assert "MISSING" in badge["text"]


def test_a_missing_firewall_warns_even_when_every_route_is_tor():
    s = _posture(MISSING)["summary"]
    assert (s["leaks"], s["level"]) == (0, "warn")
    assert _egress_badge(s)["variant"] == "warn"
    assert s["label"] == (
        "Tor-only egress firewall MISSING on the host (clearnet egress is not fail-closed; "
        "run 'pithead up'); All egress via Tor"
    )


def test_an_unverified_firewall_never_shows_green():
    s = _posture(UNVERIFIED)["summary"]
    assert s["level"] == "warn"
    assert s["label"].startswith("Egress firewall state unverified")
    assert _egress_badge(s)["variant"] == "warn"


def test_an_opted_out_firewall_ignores_the_status_file():
    p = with_firewall_state(compute_egress_posture, state=MISSING, **{**_SAFE, "firewall": False})
    assert p == compute_egress_posture(**{**_SAFE, "firewall": False})


def test_the_topology_summary_follows_the_same_state():
    t = with_firewall_state(compute_topology, state=MISSING, **{**_SAFE, "p2pool_clearnet": True})
    assert t["summary"]["firewall_state"] == MISSING
    assert not any(e.get("blocked_by_firewall") for e in t["edges"])


def test_the_status_path_is_the_fixed_read_only_mount():
    assert egress_status.STATUS_PATH == "/control/results/egress-status.json"
    assert not hasattr(egress_status, "EGRESS_STATUS_PATH")


def test_the_live_builders_read_the_host_file(tmp_path, monkeypatch):
    monkeypatch.setattr(egress.config, "TOR_EGRESS_FIREWALL", True)
    monkeypatch.setattr(egress_status, "STATUS_PATH", _write(tmp_path, {"rc": 1, "checked_at": 0}))
    monkeypatch.setattr(egress_status.time, "time", lambda: 60)
    assert egress.egress_posture_from_config()["summary"]["firewall_state"] == MISSING
    assert topology.topology_from_config()["summary"]["firewall_state"] == MISSING
    assert egress_status.live_firewall_state() == MISSING
    monkeypatch.setattr(egress.config, "TOR_EGRESS_FIREWALL", False)
    assert egress_status.live_firewall_state() is None


from mining_dashboard.service.network.egress_status import (
    WATCHDOG_CLEAN,
    WATCHDOG_LEAKING,
    WATCHDOG_NOT_OBSERVED,
    watchdog_verdict,
    live_watchdog_verdict,
)


@pytest.mark.parametrize(
    ("wd", "expected"),
    [
        ("clean", WATCHDOG_CLEAN),
        ("leaking", WATCHDOG_LEAKING),
        ("not-observed", WATCHDOG_NOT_OBSERVED),
    ],
)
def test_watchdog_verdict_reads_the_host_audit_watchdog_field(tmp_path, wd, expected):
    path = _write(tmp_path, {
        "rc": 0, "verdict": "enforced", "checked_at": NOW - 60,
        "host_audit": {"verdict": "present", "counters": [], "would_drop": 42, "watchdog": wd},
    })
    assert watchdog_verdict(path) == expected


def test_watchdog_verdict_returns_not_observed_when_no_file(tmp_path):
    assert watchdog_verdict(str(tmp_path / "absent.json")) == WATCHDOG_NOT_OBSERVED


def test_watchdog_verdict_returns_not_observed_when_no_host_audit(tmp_path):
    path = _write(tmp_path, {"rc": 0, "verdict": "enforced", "checked_at": NOW})
    assert watchdog_verdict(path) == WATCHDOG_NOT_OBSERVED


def test_watchdog_verdict_returns_not_observed_when_no_watchdog_field(tmp_path):
    path = _write(tmp_path, {
        "rc": 0, "verdict": "enforced", "checked_at": NOW,
        "host_audit": {"verdict": "present", "counters": [], "would_drop": 42},
    })
    assert watchdog_verdict(path) == WATCHDOG_NOT_OBSERVED


def test_watchdog_verdict_returns_not_observed_when_host_audit_not_a_dict(tmp_path):
    path = _write(tmp_path, {"rc": 0, "verdict": "enforced", "checked_at": NOW, "host_audit": "bad"})
    assert watchdog_verdict(path) == WATCHDOG_NOT_OBSERVED


def test_watchdog_verdict_returns_not_observed_for_unknown_value(tmp_path):
    path = _write(tmp_path, {
        "rc": 0, "verdict": "enforced", "checked_at": NOW,
        "host_audit": {"verdict": "present", "counters": [], "would_drop": 42, "watchdog": "bogus"},
    })
    assert watchdog_verdict(path) == WATCHDOG_NOT_OBSERVED


def test_live_watchdog_verdict_obeys_firewall_optout(tmp_path, monkeypatch):
    monkeypatch.setattr(egress_status, "STATUS_PATH", _write(tmp_path, {
        "rc": 0, "verdict": "enforced", "checked_at": NOW,
        "host_audit": {"verdict": "present", "counters": [], "would_drop": 42, "watchdog": "clean"},
    }))
    monkeypatch.setattr(egress.config, "TOR_EGRESS_FIREWALL", False)
    assert live_watchdog_verdict() is None
    monkeypatch.setattr(egress.config, "TOR_EGRESS_FIREWALL", True)
    assert live_watchdog_verdict() == WATCHDOG_CLEAN


def test_watchdog_edges_clean_to_leaking_fires_alert():
    from mining_dashboard.service.notify.egress_firewall_edges import EgressFirewallEdgesMixin
    m = EgressFirewallEdgesMixin()
    m.EVT_EGRESS_WATCHDOG_LEAK = "egress_watchdog_leak"
    m._fmt = lambda t: t
    m._record_incident = lambda evt: None
    assert m._egress_watchdog_edges(WATCHDOG_CLEAN) == []
    result = m._egress_watchdog_edges(WATCHDOG_LEAKING)
    assert len(result) == 1
    assert result[0][0] == "egress_watchdog_leak"
    assert "non-Tor egress" in result[0][1]


def test_watchdog_edges_leaking_to_clean_fires_recovery():
    from mining_dashboard.service.notify.egress_firewall_edges import EgressFirewallEdgesMixin
    m = EgressFirewallEdgesMixin()
    m.EVT_EGRESS_WATCHDOG_LEAK = "egress_watchdog_leak"
    m._fmt = lambda t: t
    m._record_incident = lambda evt: None
    m._egress_watchdog_edges(WATCHDOG_LEAKING)
    result = m._egress_watchdog_edges(WATCHDOG_CLEAN)
    assert len(result) == 1
    assert result[0][0] == "egress_watchdog_leak"
    assert "clean" in result[0][1].lower()


def test_watchdog_edges_not_observed_drops_baseline():
    from mining_dashboard.service.notify.egress_firewall_edges import EgressFirewallEdgesMixin
    m = EgressFirewallEdgesMixin()
    m.EVT_EGRESS_WATCHDOG_LEAK = "egress_watchdog_leak"
    m._fmt = lambda t: t
    m._record_incident = lambda evt: None
    assert m._egress_watchdog_edges(WATCHDOG_NOT_OBSERVED) == []
    assert m._prev_watchdog is None
    result = m._egress_watchdog_edges(WATCHDOG_LEAKING)
    assert len(result) == 1
    assert result[0][0] == "egress_watchdog_leak"


def test_watchdog_edges_optout_clears_state():
    from mining_dashboard.service.notify.egress_firewall_edges import EgressFirewallEdgesMixin
    m = EgressFirewallEdgesMixin()
    m.EVT_EGRESS_WATCHDOG_LEAK = "egress_watchdog_leak"
    m._fmt = lambda t: t
    m._record_incident = lambda evt: None
    m._egress_watchdog_edges(WATCHDOG_CLEAN)
    m._egress_watchdog_edges(None)
    assert m._prev_watchdog is None


def test_watchdog_edges_same_state_sends_nothing():
    from mining_dashboard.service.notify.egress_firewall_edges import EgressFirewallEdgesMixin
    m = EgressFirewallEdgesMixin()
    m.EVT_EGRESS_WATCHDOG_LEAK = "egress_watchdog_leak"
    m._fmt = lambda t: t
    m._record_incident = lambda evt: None
    m._egress_watchdog_edges(WATCHDOG_CLEAN)
    assert m._egress_watchdog_edges(WATCHDOG_CLEAN) == []
    m._egress_watchdog_edges(WATCHDOG_LEAKING)
    assert m._egress_watchdog_edges(WATCHDOG_LEAKING) == []
