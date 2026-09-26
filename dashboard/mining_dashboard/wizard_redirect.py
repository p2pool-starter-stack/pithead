"""The wizard's plain-port site: every request on :80 becomes a redirect to the TLS page.

Split out of ``wizard/server.py``; ``_run_both`` there serves ``redirect_to_tls`` beside the page.
"""

import socket

from aiohttp import web


def host_only(hostport: str) -> str:
    """Drop the port, keeping an IPv6 literal's brackets: '[fd00::1]:80' -> '[fd00::1]'."""
    if hostport.startswith("["):
        return hostport.partition("]")[0] + "]"
    return hostport.partition(":")[0]


def socket_host(request: web.Request) -> str:
    """The address this request actually arrived on — what the machine knows about itself.

    Authoritative in a way the Host header is not: it comes from the accepted socket, so it is the
    address the operator's browser genuinely reached. Falls back to the documented mDNS name when
    the transport cannot say, which is the one name every pithead answers to.
    """
    sockname = None
    if request.transport is not None:
        sockname = request.transport.get_extra_info("sockname")
    if not isinstance(sockname, (tuple, list)) or not sockname:
        return "pithead.local"
    host = str(sockname[0])
    return f"[{host}]" if ":" in host else host


def redirect_host(request: web.Request) -> str:
    """Which host the plain-port redirect should point at.

    The Host header is chosen by whoever makes the request, not by this machine, so it is honoured
    only when it names something this box answers to (#1118): the address the request arrived on,
    the machine's own hostname or FQDN, or the documented `pithead.local`. Anything else would let
    a forged header 301 the browser off the appliance mid-setup — the one screen where the operator
    types the dashboard password, and where the address bar still shows the name they typed.

    An unrecognised header falls back to the socket address rather than refusing: a wizard that
    fails closed on a box with no other way in is worse than one that redirects to the IP.
    """
    claimed = host_only(request.host or "")
    own = {socket_host(request), "pithead.local", socket.gethostname(), socket.getfqdn()}
    known = {n.lower().rstrip(".") for n in own if n}
    if claimed.lower().rstrip(".") in known:
        return claimed
    return socket_host(request)


async def redirect_to_tls(request: web.Request) -> web.Response:
    """Everything on the plain port becomes a redirect to the TLS one.

    An operator who types the address without a scheme lands on :80, and a setup page that
    simply failed there would read as a broken machine — so :80 stays open and points at :443
    rather than being closed. The host they actually used is kept when this machine recognises it,
    so the redirect works for pithead.local and for a bare address alike; see redirect_host for
    why an unrecognised one is not.
    """
    raise web.HTTPMovedPermanently(f"https://{redirect_host(request)}{request.rel_url}")
