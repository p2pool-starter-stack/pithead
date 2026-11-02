import asyncio
import os

from aiohttp import web

from mining_dashboard import go_channel

REFERENCE_FUNCTIONS = {}
_REFERENCE_MAKE_APP = None
_REFERENCE_STATE = None


def _call(operation, **extra):
    spool = os.environ.get("WIZARD_SPOOL", "/wizard-spool")
    return go_channel.call(
        "wizard",
        {
            "operation": operation,
            "spool": spool,
            "handoff": os.environ.get("WIZARD_HANDOFF", spool),
            **extra,
        },
    )


def wizard_stage():
    return _call("stage")


def installer_mode():
    return _call("installer")


def _spool_read(name, directory=None):
    return _call("read", name=name, directory=directory or "")


def _object(operation):
    return _call(operation)


def _reference():
    return _object("reference")


def _last_attempt():
    return _object("last-attempt")


def _rig_defaults():
    return _object("rig-defaults")


def _data_wiped():
    return _object("data-wiped")


def _saved_role():
    return _object("saved-role")


class Status:
    def __init__(self):
        self.task = None

    async def read(self, *args):
        if self.task is None:
            self.task = asyncio.create_task(self._run(*args))
            self.task.add_done_callback(self._finished)
        return await asyncio.shield(self.task)

    async def _run(self):
        return await asyncio.to_thread(_call, "status")

    def _finished(self, task):
        self.task = None
        if not task.cancelled():
            task.exception()

    async def close(self, app):
        del app
        if self.task is not None:
            await asyncio.gather(self.task, return_exceptions=True)


STATUS = web.AppKey("go_wizard_status", Status)


class State(Status):
    async def _run(self, request, builder):
        async with request.app["submission_lock"]:
            return await asyncio.to_thread(builder, request)


STATE = web.AppKey("go_wizard_state", State)


def prepare_app(app):
    app[STATUS] = Status()
    app.on_cleanup.append(app[STATUS].close)
    app[STATE] = State()
    app.on_cleanup.append(app[STATE].close)


async def status(request):
    return web.Response(text=await request.app[STATUS].read())


def state_builder(request):
    return asyncio.run(_REFERENCE_STATE(request))


async def wizard_state(request):
    from mining_dashboard.wizard import server

    if not server._authed(request):
        return web.json_response({"error": "unauthenticated"}, status=401)
    response = await request.app[STATE].read(request, state_builder)
    return web.Response(body=response.body, status=response.status, headers=response.headers)


def make_app(*args, **kwargs):
    app = _REFERENCE_MAKE_APP(*args, **kwargs)
    prepare_app(app)
    return app


def install(server=None):
    if server is None:
        from mining_dashboard.wizard import server

    global _REFERENCE_MAKE_APP, _REFERENCE_STATE
    if _REFERENCE_MAKE_APP is None:
        _REFERENCE_MAKE_APP = server.make_app
        _REFERENCE_STATE = server.wizard_state

    for name in (
        "wizard_stage",
        "installer_mode",
        "status",
        "_spool_read",
        "_reference",
        "_last_attempt",
        "_rig_defaults",
        "_data_wiped",
        "_saved_role",
    ):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(server, name))
        setattr(server, name, globals()[name])
    server.make_app = make_app
    server.wizard_state = wizard_state
    from mining_dashboard import go_wizard_transaction

    go_wizard_transaction.install(server)
    from mining_dashboard import go_wizard_policy

    go_wizard_policy.install(server)
    from mining_dashboard import go_wizard_config

    go_wizard_config.install(server)
    from mining_dashboard import go_wizard_terminal

    go_wizard_terminal.install(server)
    from mining_dashboard import go_wizard_submission

    go_wizard_submission.install(server)
