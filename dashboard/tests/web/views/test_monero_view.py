from mining_dashboard.web.views.views import build_pool_network


class TestMoneroCardView:
    def test_monero_health_fields_for_the_card(self, _metrics):
        # #2499: peers, the age of the last height change, and the reason text with the numbers.
        health = {
            "level": "red",
            "peers_visible": True,
            "peers_out": 0,
            "peers_in": 2,
            "advance_age_sec": 125,
            "reasons": ["0 outgoing peers for 11 min"],
            "advice": "restart monerod",
        }
        m = build_pool_network({"monero_sync": {"health": health}}, _metrics())["monero"]["health"]
        assert m["level"] == "red"
        assert m["status"] == "0 outgoing peers for 11 min"
        assert m["peers"] == "0 out / 2 in"
        assert m["moved"] == "2m 5s ago"
        assert "30 minutes" in m["tooltip"]
        health.update(level="green", reasons=[], advice="", peers_out=8)
        ok = build_pool_network({"monero_sync": {"health": health}}, _metrics())["monero"]["health"]
        assert ok["status"] == "At tip, with peers" and ok["peers"] == "8 out / 2 in"

    def test_monero_health_remote_or_absent_says_peers_not_visible(self, _metrics):
        for sync in ({"health": {"level": "unknown", "peers_visible": False}}, {}):
            h = build_pool_network({"monero_sync": sync}, _metrics())["monero"]["health"]
            assert h["level"] == "unknown" and h["peers"] == "—"
            assert "Peers not visible" in h["status"]
