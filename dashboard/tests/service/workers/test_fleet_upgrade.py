from datetime import UTC, datetime

from mining_dashboard.service.workers import fleet_upgrade

RELEASE = {"tag": "v1.15.0", "url": "https://example.invalid/r"}


def rig(name, version="1.14.0", status="online", adopted=True, api_ok=True, fresh=True):
    stamp = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ") if fresh else "2020-01-01T00:00:00Z"
    return {
        "name": name,
        "status": status,
        "adopted": adopted,
        "api_ok": api_ok,
        "rigforge": {"version": version, "generated_at": stamp},
    }


def test_plan_partitions_behind_rigs_and_names_the_reason_for_the_rest():
    workers = [
        rig("z-behind"),
        rig("a-behind", "1.2.0"),
        rig("current", "1.15.0"),
        rig("offline", status="offline"),
        rig("stale", fresh=False),
        rig("unmanaged", adopted=False),
        rig("unreachable", api_ok=False),
        {"name": "plain-xmrig", "status": "online"},
    ]
    out = fleet_upgrade.plan(workers, RELEASE)
    assert out["version"] == "v1.15.0"
    assert out["eligible"] == [
        {"name": "a-behind", "running": "1.2.0"},
        {"name": "z-behind", "running": "1.14.0"},
    ]
    skipped = {s["name"]: s["reason"] for s in out["skipped"]}
    assert set(skipped) == {"offline", "stale", "unmanaged", "unreachable"}
    assert "adopt" in skipped["unmanaged"]
    assert "control API" in skipped["unreachable"]


def test_plan_is_empty_without_a_known_release():
    assert fleet_upgrade.plan([rig("a")], None) == {"version": None, "eligible": [], "skipped": []}


def test_summary_lists_every_rig_that_did_not_cleanly_finish():
    text = fleet_upgrade.summary_text(
        {
            "version": "v1.15.0",
            "rigs": [
                {"name": "a", "status": "applied"},
                {"name": "b", "status": "failed", "reason": "build broke"},
                {"name": "c", "status": "throttled", "reason": None},
                {"name": "d", "status": "noop"},
            ],
        }
    )
    first, *rest = text.splitlines()
    assert "v1.15.0" in first and "4 rig(s)" in first and "1 upgraded" in first
    assert rest == ["• b: failed (build broke)", "• c: retry later"]


def test_latest_result_skips_unreadable_files_and_a_missing_directory(tmp_path, monkeypatch):
    monkeypatch.setattr(fleet_upgrade.config, "CONTROL_RESULTS_DIR", str(tmp_path / "gone"))
    assert fleet_upgrade.latest_result("worker-upgrade-all") is None
    monkeypatch.setattr(fleet_upgrade.config, "CONTROL_RESULTS_DIR", str(tmp_path))
    (tmp_path / "a.json").write_text("{not json")
    (tmp_path / "b.json").write_text("[1]")
    (tmp_path / "ignored.txt").write_text("{}")
    assert fleet_upgrade.latest_result("worker-upgrade-all") is None
