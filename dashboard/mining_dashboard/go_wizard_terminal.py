import asyncio
import json
import os

from aiohttp import web

from mining_dashboard import go_channel

REFERENCE_FUNCTIONS = {}


def _call(operation, authenticated, **values):
    spool = os.environ.get("WIZARD_SPOOL", "/wizard-spool")
    return go_channel.call(
        "wizard-terminal",
        {
            "operation": operation,
            "authenticated": authenticated,
            "spool": None if operation == "retry" else spool,
            "handoff": os.environ.get("WIZARD_HANDOFF", spool),
            **values,
        },
    )


def _response(result):
    if result.get("redirect"):
        raise web.HTTPFound(result["redirect"])
    body = json.loads(result["raw"]) if "raw" in result else result["body"]
    return web.json_response(body, status=result["status"], headers=result.get("headers"))


async def _handle(request, operation):
    from mining_dashboard.wizard import server

    authenticated = server._authed(request)
    if not authenticated:
        if operation == "handoff":
            return web.json_response({"error": "unauthenticated"}, status=401)
        raise web.HTTPFound("/")
    result = await asyncio.to_thread(_call, operation, authenticated)
    return _response(result)


async def handoff(request):
    return await _handle(request, "handoff")


async def handoff_ack(request):
    return await _handle(request, "ack")


async def keep_role(request):
    return await _handle(request, "keep")


def _retry(authenticated, stage, spool):
    current = stage() if authenticated else ""
    result = _call("retry", authenticated, stage=current)
    if result.get("need_spool"):
        result = _call("retry", authenticated, stage=current, spool=os.fspath(spool()))
    return result


def retry_handler(authed, stage, spool):
    lock = asyncio.Lock()

    async def run():
        async with lock:
            return await asyncio.to_thread(_retry, True, stage, spool)

    def finished(task):
        if not task.cancelled():
            task.exception()

    async def retry(request):
        if not authed(request):
            raise web.HTTPFound("/")
        task = asyncio.create_task(run())
        task.add_done_callback(finished)
        result = await asyncio.shield(task)
        return _response(result)

    return retry


def install(server):
    from mining_dashboard import wizard_recovery

    for name in ("handoff", "handoff_ack", "keep_role", "retry_handler"):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(server, name))
        setattr(server, name, globals()[name])
    wizard_recovery.retry_handler = retry_handler
