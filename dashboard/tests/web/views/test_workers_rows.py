from mining_dashboard.web.views.infra_views import build_workers


class TestWorkerRows:
    def test_unnamed_proxy_client_gets_a_labelled_row_with_its_address(self):
        rows = build_workers(
            [
                {"name": "-", "ip": "10.0.0.9", "status": "online", "h60": 2500, "accepted": 4},
                {"name": "", "ip": "10.0.0.8", "status": "online"},
                {"name": "rig-a", "ip": "10.0.0.7", "status": "online"},
            ]
        )
        by_ip = {r["ip"]: r for r in rows}
        assert by_ip["10.0.0.9"]["name"] == "unnamed proxy worker (10.0.0.9)"
        assert by_ip["10.0.0.9"]["unnamed"] is True
        assert by_ip["10.0.0.9"]["h60_str"] == "2.50 kH/s"
        assert by_ip["10.0.0.8"]["unnamed"] is True
        assert by_ip["10.0.0.7"]["name"] == "rig-a"
        assert by_ip["10.0.0.7"]["unnamed"] is False

    def test_telemetry_hashrate_has_its_own_display_string(self):
        row = build_workers(
            [{"name": "a", "ip": "1.1.1.1", "status": "offline", "telemetry_h60": 31000}]
        )[0]
        assert row["telemetry_str"] == "31.00 kH/s"
        assert row["h60_str"] == "0.00 H/s"
        silent = build_workers([{"name": "b", "ip": "1.1.1.2", "status": "online"}])[0]
        assert silent["telemetry_str"] == "—"

    def test_a_null_proxy_name_does_not_abort_the_table(self):
        rows = build_workers(
            [
                {"name": None, "ip": "10.0.0.8", "status": "online"},
                {"name": "rig-a", "ip": "10.0.0.7", "status": "online"},
            ]
        )
        assert len(rows) == 2
