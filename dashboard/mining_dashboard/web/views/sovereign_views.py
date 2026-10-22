import os
from pathlib import Path

from aiohttp import web

TEMPLATE = Path(__file__).resolve().parents[1] / "templates" / "sovereign.html"


async def handle_preview(request):
    if os.environ.get("DASHBOARD_UI_PREVIEW") != "1":
        raise web.HTTPNotFound()
    return web.FileResponse(
        TEMPLATE,
        headers={"Cache-Control": "no-store", "Content-Type": "text/html"},
    )
