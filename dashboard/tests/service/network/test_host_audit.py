import json

import pytest

from mining_dashboard.service.network import egress_status
from mining_dashboard.service.network.egress_status import host_audit_state
from mining_dashboard.service.network.topology import compute_topology
from mining_dashboard.service.network.topology_graph import CLEARNET, TOPOLOGY_NODES, UNKNOWN
from tests.service.conftest import _SAFE
from tests.web._server_support import MagicMock, StateManager, create_app

NOW = 1_800_000_000
HOST_IDS = {"host-time-sync", "host-updates", "host-containers"}
UNMONITORED = {
    "loaded": False,
    "would_drop": 0,
    "counters": [],
    "host_violations": 0,
    "unmonitored": True,
}


def _write(tmp_path, audit, checked_at=NOW - 60):
    path = tmp_path / "egress-status.json"
    body = {"rc": 0, "checked_at": checked_at}
    if audit is not None:
        body["host_audit"] = audit
    path.write_text(json.dumps(body))
    return str(path)


def _present(would_drop, counters=None):
    return {
        "verdict": "present",
        "would_drop": would_drop,
        "counters": counters if counters is not None else [{"packets": 3, "bytes": 180}],
    }


def test_loaded_with_violations(tmp_path):
    state = host_audit_state(_write(tmp_path, _present(7)), now=NOW)
    assert state == {
        "loaded": True,
        "would_drop": 7,
        "counters": [{"packets": 3, "bytes": 180}],
        "host_violations": 7,
        "unmonitored": False,
    }


def test_loaded_and_clean(tmp_path):
    state = host_audit_state(_write(tmp_path, _present(0)), now=NOW)
    assert state["loaded"] is True
    assert state["host_violations"] == 0
    assert state["unmonitored"] is False


@pytest.mark.parametrize(
    "audit",
    [
        None,
        {"verdict": "absent", "counters": [], "would_drop": None},
        {"verdict": "no-tool", "counters": [], "would_drop": None},
        {"verdict": "unreadable", "counters": [], "would_drop": None},
        {"verdict": "present", "counters": [], "would_drop": None},
        {"verdict": "present", "counters": [], "would_drop": True},
        {"verdict": "present", "counters": [], "would_drop": -1},
        {"verdict": "present", "counters": "x", "would_drop": 1},
        "present",
    ],
)
def test_audit_not_loaded_is_unmonitored(tmp_path, audit):
    assert host_audit_state(_write(tmp_path, audit), now=NOW) == UNMONITORED


def test_missing_stale_or_malformed_file_is_unmonitored(tmp_path):
    assert host_audit_state(str(tmp_path / "nope.json"), now=NOW) == UNMONITORED
    stale = _write(tmp_path, _present(5), checked_at=NOW - 3 * 120 - 1)
    assert host_audit_state(stale, now=NOW) == UNMONITORED
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    assert host_audit_state(str(bad), now=NOW) == UNMONITORED


def test_counters_keep_only_integer_packet_byte_pairs(tmp_path):
    junk = [
        {"packets": 1, "bytes": 2, "x": "y"},
        {"packets": True, "bytes": 1},
        "s",
        {"packets": 1},
    ]
    state = host_audit_state(_write(tmp_path, _present(1, junk)), now=NOW)
    assert state["counters"] == [{"packets": 1, "bytes": 2}]


async def test_endpoint_returns_audit_state(aiohttp_client, tmp_path, monkeypatch):
    path = _write(tmp_path, _present(4), checked_at=__import__("time").time())
    monkeypatch.setattr(egress_status, "STATUS_PATH", path)
    cli = await aiohttp_client(create_app(MagicMock(), {}))
    resp = await cli.get("/api/system/egress-audit")
    assert resp.status == 200
    body = await resp.json()
    assert body["loaded"] is True
    assert body["would_drop"] == 4
    assert body["counters"] == [{"packets": 3, "bytes": 180}]


async def test_endpoint_without_status_file_reports_not_loaded(
    aiohttp_client, tmp_path, monkeypatch
):
    monkeypatch.setattr(egress_status, "STATUS_PATH", str(tmp_path / "nope.json"))
    cli = await aiohttp_client(create_app(MagicMock(), {}))
    resp = await cli.get("/api/system/egress-audit")
    assert resp.status == 200
    assert await resp.json() == UNMONITORED


def test_state_json_carries_egress_audit(monkeypatch, tmp_path):
    from mining_dashboard.web.views.views import build_state

    path = _write(tmp_path, _present(2), checked_at=__import__("time").time())
    monkeypatch.setattr(egress_status, "STATUS_PATH", path)
    sm = StateManager(db_path=":memory:")
    try:
        state = build_state({"shares": [], "workers": []}, sm, "all")
    finally:
        sm.close()
    assert state["egress_audit"]["host_violations"] == 2
    assert "egress" in state and "topology" in state


def _topo(**kw):
    return compute_topology(**{**_SAFE, **kw})


def test_host_nodes_are_always_on_the_diagram():
    nodes = {n["id"]: n for n in _topo()["nodes"]}
    assert HOST_IDS <= set(nodes)
    for nid in HOST_IDS:
        assert nodes[nid]["zone"] == "host"
        assert nodes[nid]["scope"] == "host"
    assert all(n["scope"] == "host" for n in TOPOLOGY_NODES if n["id"] in HOST_IDS)


def test_host_edges_are_allowlisted_clearnet_when_audit_is_loaded():
    edges = [e for e in _topo(host_audit_loaded=True)["edges"] if e["from"] in HOST_IDS]
    assert {e["from"] for e in edges} == HOST_IDS
    for e in edges:
        assert e["to"] == "internet"
        assert e["route"] == CLEARNET
        assert e["chosen_clearnet"] is True
        assert "leak" not in e


def test_host_edges_are_not_observed_never_tor_without_audit():
    edges = [e for e in _topo()["edges"] if e["from"] in HOST_IDS]
    assert len(edges) == 3
    assert {e["route"] for e in edges} == {UNKNOWN}
    assert all("chosen_clearnet" not in e for e in edges)


@pytest.mark.parametrize(("loaded", "route"), [(True, CLEARNET), (False, UNKNOWN)])
def test_topology_from_config_reads_the_live_audit(tmp_path, monkeypatch, loaded, route):
    from mining_dashboard.service.network.topology import topology_from_config

    audit = _present(1) if loaded else {"verdict": "absent", "counters": [], "would_drop": None}
    monkeypatch.setattr(
        egress_status, "STATUS_PATH", _write(tmp_path, audit, checked_at=__import__("time").time())
    )
    edges = [e for e in topology_from_config()["edges"] if e["from"] in HOST_IDS]
    assert {e["route"] for e in edges} == {route}


def test_oversized_audit_values_are_not_trusted(tmp_path):
    assert host_audit_state(_write(tmp_path, _present(10**40)), now=NOW) == UNMONITORED
    many = [{"packets": 1, "bytes": 1}] * 500
    assert len(host_audit_state(_write(tmp_path, _present(1, many)), now=NOW)["counters"]) == 64


def test_host_edges_do_not_change_the_summary():
    assert _topo(host_audit_loaded=True)["summary"] == _topo()["summary"]
