import pytest

from mining_dashboard.service import mining_verdict as mv
from mining_dashboard.service.data_helpers import (
    _aggregate_hashrate,
    _aggregate_window_hashrates,
    _merge_direct_stats,
)
from mining_dashboard.service.metrics import build_metrics
from mining_dashboard.web.views.infra_views import build_workers

HOSTS = {"192.168.1.5", "pithead.lan"}
PORT = 3333


def _probe(pool="192.168.1.5:3333", uptime=600, **extra):
    return {"api_ok": True, "connection": {"pool": pool, "uptime": uptime}, **extra}


def _verdict(payload):
    return mv.mining_verdict(payload, HOSTS, PORT)


class TestMiningVerdict:
    def test_here_on_host_and_port_match(self):
        assert _verdict(_probe()) == {"state": "mining_here", "pool": "192.168.1.5:3333"}

    def test_here_ignores_case_and_ipv6_brackets(self):
        assert _verdict(_probe("PitHead.LAN:3333"))["state"] == "mining_here"
        v6 = mv.mining_verdict(_probe("[fd00::5]:3333"), {"fd00::5"}, PORT)
        assert v6["state"] == "mining_here"

    def test_backup_carries_reported_pool(self):
        assert _verdict(_probe("10.9.9.9:3333")) == {"state": "on_backup", "pool": "10.9.9.9:3333"}

    def test_same_host_other_port_is_not_here(self):
        assert _verdict(_probe("192.168.1.5:3344"))["state"] == "on_backup"

    def test_unparseable_pool_is_backup_not_here(self):
        assert _verdict(_probe("192.168.1.5"))["state"] == "on_backup"
        assert _verdict(_probe("192.168.1.5:\u00b2"))["state"] == "on_backup"

    def test_disconnected_rig_is_not_connected(self):
        assert _verdict(_probe("", 0)) == {"state": "not_connected", "pool": None}

    def test_no_connection_block_is_unknown(self):
        assert _verdict({"api_ok": True, "hashrate": {}})["state"] == "unknown"

    def test_malformed_connection_is_unknown(self):
        for conn in (None, "x", {}, {"pool": "192.168.1.5:3333"}, {"pool": 5, "uptime": 9}):
            assert _verdict({"api_ok": True, "connection": conn})["state"] == "unknown"
        assert _verdict(_probe(uptime=True))["state"] == "unknown"
        assert _verdict(_probe(""))["state"] == "unknown"

    def test_failed_or_missing_probe_is_unknown(self):
        assert _verdict({"api_ok": False})["state"] == "unknown"
        assert _verdict({})["state"] == "unknown"
        assert _verdict(None)["state"] == "unknown"

    def test_unknown_local_identity_never_claims_backup(self):
        assert mv.mining_verdict(_probe("10.9.9.9:3333"), set(), PORT)["state"] == "unknown"

    def test_local_hosts_skip_unconfigured_and_wildcard(self, monkeypatch):
        monkeypatch.setattr(mv.config, "HOST_IP", "Unknown Host")
        monkeypatch.setattr(mv.config, "STRATUM_BIND", "0.0.0.0")
        monkeypatch.setattr(mv, "detect_host_ipv4", lambda: None)
        assert mv.local_stratum_hosts() == set()
        monkeypatch.setattr(mv.config, "HOST_IP", "Pithead.Lan")
        monkeypatch.setattr(mv.config, "STRATUM_BIND", "127.0.0.1")
        monkeypatch.setattr(mv, "detect_host_ipv4", lambda: "192.168.1.5")
        assert mv.local_stratum_hosts() == {"pithead.lan", "127.0.0.1", "192.168.1.5"}


@pytest.fixture
def local_pithead(monkeypatch):
    monkeypatch.setattr(mv.config, "HOST_IP", "192.168.1.5")
    monkeypatch.setattr(mv.config, "STRATUM_BIND", "0.0.0.0")
    monkeypatch.setattr(mv.config, "STRATUM_PORT", 3333)
    monkeypatch.setattr(mv, "detect_host_ipv4", lambda: None)


def _row(name, h15=1000):
    return {
        "name": name,
        "ip": "10.0.0.1",
        "status": "online",
        "h10": h15,
        "h60": h15,
        "h15": h15,
        "h1h": h15,
        "h12h": h15,
        "h24h": h15,
        "uptime": 0,
    }


def _fleet(local_pithead):
    probes = [
        _probe(hashrate={"total": [7, 7, 7]}),
        _probe("10.9.9.9:3333", hashrate={"total": [5000, 5000, 5000]}),
        _probe("", 0, hashrate={"total": [0, 0, 0]}),
        {"api_ok": True, "hashrate": {"total": [9, 9, 9]}},
        {},
    ]
    rows = [_row(f"r{i}") for i in range(len(probes))]
    return _merge_direct_stats(rows, probes, "3333")


class TestMergeAndCounters:
    def test_each_row_carries_one_verdict(self, local_pithead):
        states = [w["mining"]["state"] for w in _fleet(local_pithead)]
        assert states == ["mining_here", "on_backup", "not_connected", "unknown", "unknown"]

    def test_telemetry_is_separate_and_never_summed(self, local_pithead):
        fleet = _fleet(local_pithead)
        assert fleet[1]["telemetry_h15"] == 5000
        assert fleet[1]["h15"] == 1000
        total, _ = _aggregate_hashrate(fleet)
        assert total == 1000 * 3

    def test_total_excludes_elsewhere_rows(self, local_pithead):
        total, total_h10 = _aggregate_hashrate(_fleet(local_pithead))
        assert (total, total_h10) == (3000, 3000)
        windows = _aggregate_window_hashrates(_fleet(local_pithead))
        assert windows["24h"] == 3000

    def test_workers_alive_excludes_elsewhere_rows(self, local_pithead):
        fleet = _fleet(local_pithead)
        m = build_metrics({"workers": fleet}, _mgr())
        assert (m.workers_online, m.workers_total) == (3, 5)

    def test_proxy_offline_row_with_live_telemetry_keeps_proxy_rate(self, local_pithead):
        row = _row("gone", h15=0)
        row["status"] = "offline"
        [w] = _merge_direct_stats([row], [_probe(hashrate={"total": [800, 800, 800]})], "3333")
        assert (w["h15"], w["telemetry_h15"]) == (0, 800)
        assert _aggregate_hashrate([w]) == (0, 0)

    def test_state_rows_expose_verdict_and_telemetry(self, local_pithead):
        rows = build_workers(_fleet(local_pithead))
        by = {r["name"]: r for r in rows}
        assert by["r1"]["mining"] == {"state": "on_backup", "pool": "10.9.9.9:3333"}
        assert by["r1"]["telemetry_h15"] == 5000
        assert by["r4"]["mining"] == {"state": "unknown", "pool": None}
        assert by["r4"]["telemetry_h15"] is None


def _mgr():
    from tests.service.test_metrics import _mgr as mgr

    return mgr()
