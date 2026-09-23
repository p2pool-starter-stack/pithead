"""Plain power control (#2384): POST /api/control/power for sys-reboot / sys-poweroff.

Its own module rather than server.py's, same reason as diagnostics_views: that file is at its
recorded line ceiling. Modelled directly on server.py's handle_control_os_update — a closed
action set, no operator input beyond which action, 202 + poll the existing GET
/api/control/result. Unlike os-reboot this needs no update pending; it is the plain lever an
operator has no other way to reach on a shell-less appliance.
"""

import logging

from aiohttp import web

from mining_dashboard.service import control_service

logger = logging.getLogger(__name__)

# Sibling of server.py's identical constant — see diagnostics_views.py's header for why this is
# duplicated rather than imported (avoids a server.py <-> views import cycle).
CONTROL_HEADER = "X-Pithead-Control"

# sys-poweroff does not come back on its own — the operator's typed confirmation must say so.
POWER_ACTIONS = frozenset({"reboot", "poweroff"})


async def handle_control_power(request):
    if request.headers.get(CONTROL_HEADER) != "1":
        raise web.HTTPForbidden(text="Missing X-Pithead-Control header.")
    try:
        body = await request.json()
    except Exception:
        raise web.HTTPBadRequest(text="Body must be JSON.") from None
    if not isinstance(body, dict):
        raise web.HTTPBadRequest(text="Body must be a JSON object.")
    action = body.get("action")
    if not isinstance(action, str) or action not in POWER_ACTIONS:
        raise web.HTTPBadRequest(
            text="'action' must be one of: " + ", ".join(sorted(POWER_ACTIONS))
        )
    try:
        rid = control_service.submit(f"sys-{action}", actor=request.headers.get("X-Auth-User", ""))
    except Exception:
        logger.exception("Error submitting power request")
        return web.json_response({"error": "Failed to submit the power request."}, status=500)
    return web.json_response({"id": rid, "status": "pending"}, status=202)
