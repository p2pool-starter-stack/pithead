import io
import json
import re
import tarfile
import uuid

from aiohttp import web

from mining_dashboard.config import config
from mining_dashboard.service import control_service, request_spool
from mining_dashboard.web.views import sovereign_views

SERVICES = frozenset(
    (
        "tor",
        "monerod",
        "tari",
        "p2pool",
        "xmrig-proxy",
        "dashboard",
        "docker-proxy",
        "docker-control",
        "caddy",
    )
)
MAX_REPORT_BYTES = 65536


def register_routes(app):
    app.router.add_get("/ui-preview", sovereign_views.handle_preview)
    if config.DASHBOARD_CONTROL_ENABLED:
        app.router.add_post("/api/control/diag-bundle", handle_collect)
        app.router.add_post("/api/control/bundle-download", handle_download)


def result_response(request, result):
    if result.get("kind") == "diag-bundle":
        actor = request.headers.get("X-Auth-User", "")
        if not actor or result.get("actor") != actor:
            raise web.HTTPForbidden(text="This bundle belongs to a different session identity.")
        if result.get("status") == "applied":
            bundle_members(result, actor)
        return web.json_response(result, headers={"Cache-Control": "no-store"})
    return web.json_response(result)


def require_actor(request):
    if request.headers.get("X-Pithead-Control") != "1":
        raise web.HTTPForbidden(text="Missing X-Pithead-Control header.")
    actor = request.headers.get("X-Auth-User", "")
    if not re.fullmatch(r"[A-Za-z0-9._@-]{1,64}", actor):
        raise web.HTTPForbidden(text="Sign in before collecting diagnostics.")
    return actor


async def handle_collect(request):
    actor = require_actor(request)
    rid = str(uuid.uuid4())
    try:
        request_spool.write({"id": rid, "action": "diag-bundle", "actor": actor})
    except OSError:
        raise web.HTTPServiceUnavailable(
            text="Could not submit the browser bundle request."
        ) from None
    return web.json_response(
        {"id": rid, "status": "pending"}, status=202, headers={"Cache-Control": "no-store"}
    )


def bundle_members(result, actor):
    if not result or result.get("status") != "applied" or result.get("kind") != "diag-bundle":
        raise web.HTTPNotFound(text="No completed browser bundle for that id.")
    if result.get("actor") != actor:
        raise web.HTTPForbidden(text="This bundle belongs to a different session identity.")
    bundle = result.get("bundle")
    if not isinstance(bundle, dict) or set(bundle) != {"doctor", "logs"}:
        raise web.HTTPConflict(text="The browser bundle is not readable.")
    doctor, logs = bundle["doctor"], bundle["logs"]
    if not isinstance(doctor, dict) or not isinstance(logs, dict) or set(logs) != SERVICES:
        raise web.HTTPConflict(text="The browser bundle has unexpected reports.")
    members = {"doctor.json": json.dumps(doctor, ensure_ascii=False).encode()}
    for service, text in logs.items():
        if not isinstance(text, str) or len(text.encode()) > MAX_REPORT_BYTES:
            raise web.HTTPConflict(text="A service report exceeds the browser bound.")
        members[f"logs/{service}.log"] = text.encode()
    if len(members["doctor.json"]) > MAX_REPORT_BYTES * 2:
        raise web.HTTPConflict(text="The doctor report exceeds the browser bound.")
    return members


async def handle_download(request):
    actor = require_actor(request)
    try:
        body = await request.json()
        if (
            not isinstance(body, dict)
            or set(body) != {"id", "reviewed"}
            or body["reviewed"] is not True
        ):
            raise ValueError
        rid = str(uuid.UUID(body["id"]))
    except (ValueError, TypeError, AttributeError, KeyError):
        raise web.HTTPBadRequest(text="Review the identifiers and supply the bundle id.") from None
    members = bundle_members(control_service.result(rid), actor)
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w:gz") as stream:
        for name, data in members.items():
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            entry.mode = 0o600
            stream.addfile(entry, io.BytesIO(data))
    return web.Response(
        body=archive.getvalue(),
        content_type="application/gzip",
        headers={
            "Content-Disposition": 'attachment; filename="pithead-browser-support.tar.gz"',
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        },
    )
