import logging

from aiohttp import web

from mining_dashboard.service.network.egress_status import host_audit_state

logger = logging.getLogger(__name__)


async def handle_egress_audit(request):
    try:
        return web.json_response(host_audit_state())
    except Exception:
        logger.exception("Error reading the host egress audit")
        return web.json_response({"error": "Failed to read the host egress audit."}, status=500)


def egress_audit_routes():
    return [web.get("/api/system/egress-audit", handle_egress_audit)]
