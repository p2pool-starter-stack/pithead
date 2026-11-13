from datetime import UTC, datetime

from mining_dashboard.service.workers import worker_refresh


async def _fake_sleep(_):
    return None


class FakeWorkerClient:
    def __init__(self, versions):
        self._versions = list(versions)
        self.calls = []

    async def get_stats(self, ip, name):
        self.calls.append((ip, name))
        version = self._versions.pop(0)
        return {
            "generated_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "rigforge": {"version": version},
        }


class TestRefreshSurvivesMainLoopSwap:
    async def test_write_lands_in_the_current_entry_after_a_swap(self):
        old = {"name": "rig1", "ip": "10.0.0.5"}
        data = {"workers": [old]}
        fresh = {"name": "rig1", "ip": "10.0.0.5"}

        async def swap_sleep(_):
            data["workers"] = [fresh]

        client = FakeWorkerClient(["1.12.0"])
        ok = await worker_refresh.refresh_worker_after_upgrade(
            data, "rig1", "v1.12.0", worker_client=client, attempts=2, sleep=swap_sleep
        )
        assert ok is True
        assert fresh["rigforge"]["version"] == "1.12.0"
        assert "rigforge" not in old

    async def test_worker_dropped_or_readdressed_mid_refresh_stops_without_writing(self):
        entry = {"name": "rig1", "ip": "10.0.0.5"}
        data = {"workers": [entry]}
        moved = {"name": "rig1", "ip": "10.0.0.99"}

        async def readdress_sleep(_):
            data["workers"] = [moved]

        client = FakeWorkerClient(["1.12.0"])
        ok = await worker_refresh.refresh_worker_after_upgrade(
            data, "rig1", "v1.12.0", worker_client=client, attempts=3, sleep=readdress_sleep
        )
        assert ok is False
        assert "rigforge" not in moved
        assert len(client.calls) == 1


class TestRefreshKeepsNewerReport:
    async def test_older_probe_does_not_clobber_a_newer_main_loop_report(self):
        newer = {"version": "1.12.0", "generated_at": "2999-01-01T00:00:00Z"}
        entry = {"name": "rig1", "ip": "10.0.0.5", "rigforge": newer}
        ok = await worker_refresh.refresh_worker_after_upgrade(
            {"workers": [entry]},
            "rig1",
            "v1.12.0",
            worker_client=FakeWorkerClient(["1.11.0"]),
            attempts=1,
            sleep=_fake_sleep,
        )
        assert ok is False
        assert entry["rigforge"] is newer


async def test_report_without_a_stamp_is_tolerated():
    held = {"version": "1.11.0", "generated_at": None}
    entry = {"name": "rig1", "ip": "10.0.0.5", "rigforge": held}
    client = FakeWorkerClient(["1.12.0"])
    ok = await worker_refresh.refresh_worker_after_upgrade(
        {"workers": [entry]}, "rig1", "v1.12.0", worker_client=client, attempts=1, sleep=_fake_sleep
    )
    assert ok is True
    assert entry["rigforge"]["version"] == "1.12.0"


async def test_stamped_probe_replaces_a_held_report_without_a_stamp():
    entry = {"name": "rig1", "ip": "10.0.0.5", "rigforge": {"version": "1.11.0"}}
    client = FakeWorkerClient(["1.12.0"])
    ok = await worker_refresh.refresh_worker_after_upgrade(
        {"workers": [entry]}, "rig1", "v1.12.0", worker_client=client, attempts=1, sleep=_fake_sleep
    )
    assert ok is True
    assert entry["rigforge"]["version"] == "1.12.0"
