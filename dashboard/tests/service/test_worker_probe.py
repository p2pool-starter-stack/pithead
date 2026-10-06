import asyncio

from mining_dashboard.service.data_helpers import _merge_direct_stats
from mining_dashboard.service.worker_probe import WorkerProber


class _Client:
    """Records probes; ``answers`` maps name -> result (default: the probe fails)."""

    def __init__(self, answers):
        self.answers = answers
        self.probed = []

    async def get_stats(self, ip, name):
        self.probed.append(name)
        return self.answers.get(name, {"api_ok": False, "adopted": False})


def _w(name, status):
    return {"name": name, "ip": "8.8.8.8", "status": status, "uptime": 0}


def _run(prober, client, workers):
    return asyncio.run(prober.probe(client, workers))


def test_offline_row_whose_last_probe_failed_is_not_probed_or_badged():
    client, prober = _Client({}), WorkerProber()
    workers = [_w("ghost", "offline")]
    assert _run(prober, client, workers) == [{}]
    assert client.probed == []
    [row] = _merge_direct_stats(workers, [{}], "3333")
    assert "api_ok" not in row


def test_online_row_is_probed():
    client = _Client({"rig": {"api_ok": True}})
    assert _run(WorkerProber(), client, [_w("rig", "online")]) == [{"api_ok": True}]
    assert client.probed == ["rig"]


def test_online_row_with_failing_probe_is_badged_and_stops_when_it_goes_offline():
    client, prober = _Client({}), WorkerProber()
    [r] = _run(prober, client, [_w("rig", "online")])
    assert r["api_ok"] is False
    assert _run(prober, client, [_w("rig", "offline")]) == [{}]
    assert client.probed == ["rig"]


def test_stopped_miner_whose_feed_answered_is_still_probed():
    client = _Client({"rig": {"api_ok": True}})
    prober = WorkerProber()
    _run(prober, client, [_w("rig", "online")])
    assert _run(prober, client, [_w("rig", "offline")]) == [{"api_ok": True}]
    assert client.probed == ["rig", "rig"]


def test_reconnecting_rig_returns_to_probe_set():
    client, prober = _Client({"rig": {"api_ok": True}}), WorkerProber()
    assert _run(prober, client, [_w("rig", "offline")]) == [{}]
    assert client.probed == []
    assert _run(prober, client, [_w("rig", "online")]) == [{"api_ok": True}]
    client.answers = {}
    _run(prober, client, [_w("rig", "offline")])  # answered last cycle: probed, now fails
    assert _run(prober, client, [_w("rig", "offline")]) == [{}]


def test_mixed_list_stays_aligned():
    client = _Client({"a": {"api_ok": True, "id": "a"}, "c": {"api_ok": True, "id": "c"}})
    workers = [_w("a", "online"), _w("ghost", "offline"), _w("c", "online")]
    results = _run(WorkerProber(), client, workers)
    assert [r.get("id") for r in results] == ["a", None, "c"]
    assert results[1] == {}
