import asyncio
import logging
import time

from aiohttp import web

from mining_dashboard.service import control_service
from mining_dashboard.service.workers import fleet_upgrade, worker_refresh

logger = logging.getLogger(__name__)

CONTROL_HEADER = "X-Pithead-Control"
RUN_WAIT_S = 4 * 3600


def _require_control_header(request):
    if request.headers.get(CONTROL_HEADER) != "1":
        raise web.HTTPForbidden(text="Missing X-Pithead-Control header.")


async def handle_fleet_upgrade_state(request):
    data = request.app["latest_data"] or {}
    body = fleet_upgrade.plan(data.get("workers", []), data.get("rigforge_release"))
    body["run"] = await asyncio.to_thread(fleet_upgrade.latest_result, "worker-upgrade-all")
    return web.json_response(body)


async def _finalize(app, rid, version):
    try:
        res = await control_service.wait_result(
            rid, done=lambda r: r.get("status") != fleet_upgrade.RUNNING, timeout_s=RUN_WAIT_S
        )
    except Exception:
        logger.exception("Error waiting for worker-upgrade-all result (id=%s)", rid)
        return
    if res is None:
        return
    state_mgr = app["state_manager"]
    for rig in res.get("rigs") or []:
        if rig.get("status") in ("not_started",):
            continue
        state_mgr.add_worker_config_version(
            rig["name"],
            rig.get("change_id"),
            rig["status"],
            {"version": version},
            rig.get("reason"),
            change_type="upgrade",
        )
        await worker_refresh.maybe_refresh_after_upgrade(
            app["latest_data"], rig["name"], version, rig
        )
    notify = app.get("notify")
    if notify:
        await notify(fleet_upgrade.summary_text(res))


async def handle_fleet_upgrade_start(request):
    _require_control_header(request)
    try:
        body = await request.json()
    except Exception:
        raise web.HTTPBadRequest(text="Body must be JSON.") from None
    data = request.app["latest_data"] or {}
    plan = fleet_upgrade.plan(data.get("workers", []), data.get("rigforge_release"))
    if body.get("version") != plan["version"] or not plan["version"]:
        raise web.HTTPConflict(
            text="The latest RigForge release changed — reload and review again."
        )
    if not plan["eligible"]:
        raise web.HTTPConflict(text="No managed rig is behind the latest release.")
    last = await asyncio.to_thread(fleet_upgrade.latest_result, "worker-upgrade-all")
    if (
        last
        and last.get("status") == fleet_upgrade.RUNNING
        and time.time() - last.get("ts", 0) < RUN_WAIT_S
    ):
        raise web.HTTPConflict(text="An Update all run is already in progress.")
    names = [r["name"] for r in plan["eligible"]]
    try:
        rid = fleet_upgrade.submit_worker_upgrade_all(
            names, plan["version"], request.headers.get("X-Auth-User", "")
        )
    except Exception:
        logger.exception("Error submitting worker-upgrade-all")
        return web.json_response({"error": "Failed to submit the fleet upgrade."}, status=500)
    task = asyncio.create_task(_finalize(request.app, rid, plan["version"]))
    request.app["_bg_tasks"].add(task)
    task.add_done_callback(request.app["_bg_tasks"].discard)
    return web.json_response({"id": rid, "status": "pending", "rigs": names}, status=202)


def routes():
    path = "/api/control/worker-upgrade-all"
    return [
        web.get(path, handle_fleet_upgrade_state),
        web.post(path, handle_fleet_upgrade_start),
    ]
