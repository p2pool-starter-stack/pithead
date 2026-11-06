from unittest.mock import patch

import pytest

from mining_dashboard.service.xvb import algo_service


@pytest.mark.parametrize("mode", ["P2POOL", "XVB"])
@pytest.mark.parametrize("tor", [False, True])
async def test_full_pool_objects_at_controller_boundary(algo, mode, tor):
    algo.proxy_client.get_config.return_value = {"pools": [], "other": "keep"}
    with (
        patch.object(algo_service, "P2POOL_URL", "local-pool.invalid:3333"),
        patch.object(algo_service, "MONERO_WALLET_ADDRESS", "fixture-wallet"),
        patch.object(algo_service, "XVB_POOL_URL", "external-pool.invalid:3333"),
        patch.object(algo_service, "XVB_DONOR_ID", "fixture-donor"),
        patch.object(algo_service, "XVB_TOR_ENABLED", tor),
        patch.object(algo_service, "XVB_TOR_SOCKS5", "relay.invalid:9050"),
    ):
        await algo.switch_miners(mode)
    local = {
        "url": "local-pool.invalid:3333",
        "user": "fixture-wallet",
        "pass": "x",
        "coin": "monero",
        "enabled": mode == "P2POOL",
    }
    external = {
        "url": "external-pool.invalid:3333",
        "user": "fixture-donor",
        "pass": "x",
        "coin": "monero",
        "enabled": mode == "XVB",
    }
    if tor:
        external["socks5"] = "relay.invalid:9050"
    pools = [local, external] if mode == "P2POOL" else [external, local]
    algo.proxy_client.update_config.assert_called_once_with({"pools": pools, "other": "keep"})
