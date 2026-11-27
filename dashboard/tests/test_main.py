import asyncio
from unittest import mock

from aiohttp import web

from mining_dashboard import main as dashboard_main
from mining_dashboard.main import build_app
from mining_dashboard.service.data_service import DataService
from mining_dashboard.service.notify import healthchecks as hc_mod


def test_build_app_returns_wired_application():
    """build_app() must construct the full app graph with no network/DB side effects
    at import time (the DB is redirected to a temp file by the conftest fixture)."""
    app = build_app()
    try:
        assert isinstance(app, web.Application)
        assert app["state_manager"] is not None
        # The index route is registered.
        assert any(getattr(r, "handler", None) for r in app.router.routes())
        # Startup/cleanup hooks are wired for the background tasks.
        assert app.on_startup and app.on_cleanup
    finally:
        app["state_manager"].close()


def test_main_drains_connections_inside_the_engine_grace_period():
    """The default 60s aiohttp drain outlasts the engine's stop timeout, so a recreate SIGKILLs the
    dashboard and the stop API can answer 500 (#3300)."""
    with (
        mock.patch.object(dashboard_main, "build_app") as build,
        mock.patch.object(dashboard_main.web, "run_app") as run_app,
    ):
        dashboard_main.main()
    assert run_app.call_args.args == (build.return_value,)
    assert run_app.call_args.kwargs["shutdown_timeout"] == dashboard_main.SHUTDOWN_TIMEOUT
    assert dashboard_main.SHUTDOWN_TIMEOUT <= 5


async def test_ping_task_keeps_pinging_while_the_data_loop_is_dead():
    pings = []
    with (
        mock.patch.object(hc_mod, "HEALTHCHECKS_PING_URL", "https://hc-ping.com/abc"),
        mock.patch.object(hc_mod, "_PING_INTERVAL_SEC", 1),
        mock.patch.object(
            hc_mod.HealthchecksClient, "ping", autospec=True, side_effect=lambda c: pings.append(1)
        ),
        mock.patch.object(DataService, "run", side_effect=RuntimeError("loop dead")),
    ):
        app = build_app()
        for hook in app.on_startup:
            await hook(app)
        await asyncio.sleep(1.5)
        for hook in app.on_cleanup:
            await hook(app)
    assert app["data_task"].done()
    assert len(pings) >= 2
