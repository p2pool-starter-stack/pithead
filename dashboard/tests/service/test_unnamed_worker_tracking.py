from mining_dashboard.service.data_helpers import WorkerLifecycle
from mining_dashboard.service.workers.worker_presence import WorkerPresenceMonitor


def _rows(up_status, down_status):
    return [
        {"name": "-", "ip": "192.0.2.1", "status": up_status, "uptime": 0},
        {"name": "-", "ip": "192.0.2.2", "status": down_status, "uptime": 0},
    ]


def test_lifecycle_tracks_unnamed_rigs_separately():
    lc = WorkerLifecycle(3600)
    lc.update(_rows("online", "offline"), 1000.0)
    live = lc.update(_rows("online", "offline"), 1150.0)
    assert [w["ip"] for w in live] == ["192.0.2.1", "192.0.2.2"]
    assert live[0]["uptime"] == 150
    live = lc.update(_rows("online", "offline"), 1000.0 + 3601)
    assert [w["ip"] for w in live] == ["192.0.2.1"]


def test_presence_reports_offline_for_dead_unnamed_rig():
    mon = WorkerPresenceMonitor(offline_after=60, recovery_after=60)
    mon.update(_rows("online", "online"), 0.0)
    mon.update(_rows("online", "offline"), 10.0)
    edges = mon.update(_rows("online", "offline"), 100.0)
    assert edges == [("-@192.0.2.2", "offline")]


def test_named_rig_keeps_its_name():
    mon = WorkerPresenceMonitor(offline_after=60, recovery_after=60)
    rows = [{"name": "rig-1", "ip": "192.0.2.3", "status": "offline"}]
    mon.update([{**rows[0], "status": "online"}], 0.0)
    mon.update(rows, 10.0)
    assert mon.update(rows, 100.0) == [("rig-1", "offline")]
