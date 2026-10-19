import asyncio

from test_contract import TariWalletClient, start_wallet_server


def test_tari_wallet_address_probe_uses_real_grpc_method():
    async def check():
        server, bound = await start_wallet_server(0, {"transactions": [], "address": "wallet-a"})
        client = TariWalletClient(grpc_address=f"127.0.0.1:{bound}")
        try:
            assert await client.payout_addresses("wallet-a") == (["wallet-a"], True)
            assert await client.scan() == ([], True)
        finally:
            await client.close()
            await server.stop(None)

    asyncio.run(check())
