# ruff: noqa: F403, F405
from tests.service.xvb._algo_service_support import *  # noqa: F403


class TestSwitchMiners:
    async def test_switch_updates_proxy_and_state(self, algo):
        algo.proxy_client.get_config.return_value = {"pools": [], "other": "keep"}
        await algo.switch_miners("XVB")
        algo.proxy_client.update_config.assert_called_once()
        sent = algo.proxy_client.update_config.call_args[0][0]
        assert sent["other"] == "keep"  # preserves existing config
        assert sent["pools"][0]["enabled"] is True
        algo.state_manager.update_xvb_stats.assert_called_once()

    async def test_switch_aborts_on_bad_config(self, algo):
        algo.proxy_client.get_config.return_value = None
        await algo.switch_miners("P2POOL")
        algo.proxy_client.update_config.assert_not_called()

    async def test_xvb_pool_routed_over_tor_by_default(self, algo):
        # #166: the XvB pool carries a per-pool socks5 (Tor); the local p2pool pool never does.
        algo.proxy_client.get_config.return_value = {"pools": []}
        with (
            patch("mining_dashboard.service.xvb.algo_service.XVB_TOR_ENABLED", True),
            patch("mining_dashboard.service.xvb.algo_service.XVB_TOR_SOCKS5", "172.28.0.25:9050"),
        ):
            await algo.switch_miners("XVB")
        pools = algo.proxy_client.update_config.call_args[0][0]["pools"]
        xvb, local = pools[0], pools[1]  # enabled XvB pool first in XVB mode
        assert xvb["enabled"] is True and xvb["socks5"] == "172.28.0.25:9050"
        assert "socks5" not in local  # local p2pool dials direct, never via Tor

    async def test_local_pool_never_routed_over_tor(self, algo):
        # Even in P2POOL mode (XvB pool present but disabled), only the XvB pool carries socks5.
        algo.proxy_client.get_config.return_value = {"pools": []}
        with (
            patch("mining_dashboard.service.xvb.algo_service.XVB_TOR_ENABLED", True),
            patch("mining_dashboard.service.xvb.algo_service.XVB_TOR_SOCKS5", "172.28.0.25:9050"),
        ):
            await algo.switch_miners("P2POOL")
        pools = algo.proxy_client.update_config.call_args[0][0]["pools"]
        local, xvb = pools[0], pools[1]  # enabled local pool first in P2POOL mode
        assert "socks5" not in local
        assert xvb["socks5"] == "172.28.0.25:9050"

    async def test_xvb_tor_opt_out_no_socks5(self, algo):
        # xvb.tor:false → XVB_TOR_ENABLED False → no pool carries socks5 (direct clearnet, max yield).
        algo.proxy_client.get_config.return_value = {"pools": []}
        with patch("mining_dashboard.service.xvb.algo_service.XVB_TOR_ENABLED", False):
            await algo.switch_miners("XVB")
        pools = algo.proxy_client.update_config.call_args[0][0]["pools"]
        assert all("socks5" not in p for p in pools)
