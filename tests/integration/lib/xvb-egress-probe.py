"""Run one real XvB fetch while refusing every socket path except the configured Tor SOCKS."""
# ruff: noqa: E402, I001, S101 -- imports intentionally follow the dependency-free self-test

import os
import socket
import sys
from urllib.parse import urlparse


def allowed(address, proxy_addresses, proxy_port):
    return (
        isinstance(address, tuple)
        and len(address) >= 2
        and str(address[0]) in proxy_addresses
        and address[1] == proxy_port
    )


proxy_host = "172.28.0.25"
proxy_port = 9050
proxy_addresses = {proxy_host}
connected = []


def guard_socket(event, args):
    if event == "socket.connect":
        address = args[1]
        if not allowed(address, proxy_addresses, proxy_port):
            raise OSError("non-Tor socket refused by XvB live probe")
        connected.append(address)
        return
    if event == "socket.sendto" or event.startswith("subprocess.") or event == "os.system":
        raise OSError("datagram or subprocess refused by XvB live probe")
    if event in {"socket.getaddrinfo", "socket.gethostbyname", "socket.gethostbyaddr"}:
        host = args[0]
        if str(host) != proxy_host:
            raise OSError("non-Tor DNS refused by XvB live probe")
        return


if sys.argv[1:] == ["--self-test"]:
    assert allowed(("172.28.0.25", 9050), {"172.28.0.25"}, 9050)
    assert not allowed(("172.28.0.25", 53), {"172.28.0.25"}, 9050)
    assert not allowed(("1.1.1.1", 9050), {"172.28.0.25"}, 9050)
    guard_socket("socket.connect", (None, ("172.28.0.25", 9050)))
    try:
        guard_socket("socket.getaddrinfo", ("xmrvsbeast.com", 443))
    except OSError:
        pass
    else:
        raise AssertionError("clearnet DNS was not refused")
    for event in ("socket.sendto", "subprocess.Popen"):
        try:
            guard_socket(event, ())
        except OSError:
            pass
        else:
            raise AssertionError(f"{event} was not refused")
    raise SystemExit(0)


proxy = urlparse(os.environ["TOR_SOCKS_PROXY"])
proxy_host = proxy.hostname or ""
proxy_port = proxy.port or 0
proxy_addresses = {
    address[4][0] for address in socket.getaddrinfo(proxy_host, proxy_port, type=socket.SOCK_STREAM)
}
connected = []

sys.addaudithook(guard_socket)
from mining_dashboard.client.xvb_client import XvbClient  # noqa: E402
from mining_dashboard.config.config import MONERO_WALLET_ADDRESS  # noqa: E402

ok = XvbClient(MONERO_WALLET_ADDRESS).get_stats() is not None
raise SystemExit(
    0 if ok and any(allowed(address, proxy_addresses, proxy_port) for address in connected) else 1
)
