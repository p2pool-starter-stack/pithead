"""Connection credentials, separately from the cached dashboard state."""

import os

from aiohttp import web

from mining_dashboard.config import config
from mining_dashboard.web.views.header import host_display_addr


def stratum_endpoint():
    bind = config.STRATUM_BIND
    host = bind if bind != "0.0.0.0" else host_display_addr(config.HOST_IP) or config.HOST_IP
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    return host, bind == "127.0.0.1"


async def handle_miner_connection(request):
    password = os.environ.get("PROXY_STRATUM_PASSWORD", "")
    # Every route sits behind Caddy's configured login. The owner also permits credentials
    # on a login-free LAN dashboard; published onion dashboards require authentication.
    host, local_only = stratum_endpoint()
    tls = os.environ.get("PROXY_STRATUM_TLS") == "true"
    body = {
        "url": f"stratum+{'ssl' if tls else 'tcp'}://{host}:{config.STRATUM_PORT}",
        "local_only": local_only,
        "password_set": bool(password),
        "password": password,
        "tls": tls,
        "fingerprint": os.environ.get("STRATUM_TLS_FINGERPRINT", "") if tls else "",
    }
    return web.json_response(body, headers={"Cache-Control": "no-store"})
