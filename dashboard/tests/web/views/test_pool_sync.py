from mining_dashboard.web.views.views import build_pool_network


def test_sidechain_sync_flag_reaches_browser_without_changing_local_hashrate(_metrics):
    result = build_pool_network({"pool": {"pool": {"syncing": True}}}, _metrics(stratum_h1h=1234))
    assert result["pool"]["syncing"] is True
    assert result["stratum"]["h1h"] == "1.23 kH/s"
    assert build_pool_network({}, _metrics())["pool"]["syncing"] is False
