"""Read addresses from the pinned wallet binaries, without a chain or fake wallet."""

import sys
import time

import grpc
import requests
from requests.auth import HTTPDigestAuth

from mining_dashboard.client.tari.generated import types_pb2, wallet_pb2_grpc


def address(chain):
    if chain == "monero":
        response = requests.post(
            "http://wallet-rpc:18082/json_rpc",
            json={"jsonrpc": "2.0", "id": "0", "method": "get_address"},
            auth=HTTPDigestAuth("wallet", "itest"),
            timeout=3,
        )
        response.raise_for_status()
        return response.json()["result"]["address"]
    with grpc.insecure_channel("tari-wallet:18143") as channel:
        reply = wallet_pb2_grpc.WalletStub(channel).GetCompleteAddress(types_pb2.Empty(), timeout=3)
        return reply.one_sided_address_base58


chain, expected, verdict = sys.argv[1:]
for _ in range(10 if verdict == "unavailable" else 40):
    try:
        actual = address(chain)
        if verdict == "unavailable":
            sys.exit(f"{chain} wallet answered despite the rejected view key")
        break
    except (requests.RequestException, grpc.RpcError, KeyError):
        time.sleep(2)
else:
    if verdict == "unavailable":
        print(f"{chain} wallet address RPC stayed unavailable after the rejected view key")
        sys.exit(0)
    sys.exit(f"{chain} wallet did not answer its address RPC within 80 seconds")

if verdict == "match" and actual == expected:
    print(f"{chain} wallet answered with the configured payout address")
elif verdict == "mismatch" and actual != expected:
    print(f"{chain} view key does not derive the configured payout address")
else:
    sys.exit(f"{chain} wallet address identity verdict was {verdict}, got another result")
