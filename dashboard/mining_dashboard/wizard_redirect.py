"""Redirect the wizard's plain port to TLS using host-owned names and addresses."""

import ipaddress
import os
import socket

from aiohttp import web


def host_only(hostport: str) -> str:
    """Drop the port, keeping an IPv6 literal's brackets."""
    if hostport.startswith("["):
        return hostport.partition("]")[0] + "]"
    return hostport.partition(":")[0]


def host_addresses() -> list[str]:
    """Host-provided global interface addresses, excluding bridges at container launch."""
    addresses = []
    for value in os.environ.get("WIZARD_HOST_ADDRESSES", "").split():
        try:
            address = ipaddress.ip_address(value)
        except ValueError:
            continue
        if address.is_unspecified or address.is_loopback or address.is_link_local:
            continue
        host = str(address)
        addresses.append(f"[{host}]" if address.version == 6 else host)
    return addresses


def redirect_host(request: web.Request) -> str:
    """Honour only names the appliance owns; never use the container's socket address.

    The host passes non-bridge interface addresses to the container. Unknown Host headers
    fall back to the first such address, or pithead.local when none is available. This keeps
    a forged header from redirecting the operator off the appliance during password setup.
    """
    addresses = host_addresses()
    claimed = host_only(request.host or "")
    own = {*addresses, "pithead.local", socket.gethostname(), socket.getfqdn()}
    known = {n.lower().rstrip(".") for n in own if n}
    if claimed.lower().rstrip(".") in known:
        return claimed
    return addresses[0] if addresses else "pithead.local"


async def redirect_to_tls(request: web.Request) -> web.Response:
    """Keep a recognised typed host when redirecting a scheme-less URL to TLS."""
    raise web.HTTPMovedPermanently(f"https://{redirect_host(request)}{request.rel_url}")
