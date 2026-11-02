import logging

from aiohttp import web

from mining_dashboard.service import control_service

logger = logging.getLogger(__name__)

CONTROL_HEADER = "X-Pithead-Control"

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
