import os
from contextlib import contextmanager
from pathlib import Path

import pytest
from dashboard_fleet_session import JSONSession

pytest_plugins = ["dashboard_fleet_plugin"]

REPO_ROOT = Path(__file__).resolve().parents[2]
BINARY = REPO_ROOT / "go" / "bin" / "dashboard"
OPERATIONS = (
    "build_pool_network",
    "build_raffle_log",
    "build_raffle_eligibility",
    "_egress_badge",
    "visible_update",
    "build_badges",
)
ORIGINALS = {}
OVERVIEW = None
BADGES = None


def _run(operation, args):
    from mining_dashboard import go_overview

    session = BADGES if operation == "build_badges" else OVERVIEW
    if session is None:
        raise RuntimeError("Go overview helper is unavailable")
    return session.run(go_overview.request(operation, args))


def native_build_pool_network(data, metrics, monero_builder=None):
    from mining_dashboard.web.views import views

    monero = (views.build_monero if monero_builder is None else monero_builder)(data, metrics)
    return _run("build_pool_network", [data, metrics, monero])


def native_build_raffle_log(wins):
    return _run("build_raffle_log", [wins])


def native_build_raffle_eligibility(metrics):
    return _run("build_raffle_eligibility", [metrics])


def native__egress_badge(summary):
    return _run("_egress_badge", [summary])


def native_visible_update(update, running=None):
    from mining_dashboard.web.views import views

    if update and running is None:
        running = (views.resolve_version() or {}).get("text")
    return _run("visible_update", [update, running])


def native_build_badges(data, metrics, mode_variant, db_healthy=True, wallet_change=None):
    from mining_dashboard import go_overview

    if wallet_change:
        wallet_change = {
            **wallet_change,
            "old8": str(wallet_change["old8"]),
            "new8": str(wallet_change["new8"]),
        }
    return _run(
        "build_badges",
        [data, metrics, mode_variant, db_healthy, wallet_change, go_overview.badge_settings()],
    )


NATIVES = {
    name.removeprefix("native_"): value
    for name, value in tuple(globals().items())
    if name.startswith("native_")
}


def _set_operations(values):
    from mining_dashboard.web.views import views, xvb_views

    for name in OPERATIONS:
        setattr(views, name, values[name])
    xvb_views.build_badges = values["build_badges"]


@contextmanager
def python_operations():
    import dashboard_fleet_plugin

    with dashboard_fleet_plugin.python_operations():
        _set_operations(ORIGINALS)
        try:
            yield
        finally:
            _set_operations(NATIVES)


def python_call(operation, *args, **kwargs):
    with python_operations():
        return ORIGINALS[operation](*args, **kwargs)


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard.web.views import views

    ORIGINALS.update({name: getattr(views, name) for name in OPERATIONS})
    _set_operations(NATIVES)


@pytest.hookimpl(hookwrapper=True)
def pytest_sessionstart(session):
    yield
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    if session.config.pluginmanager.get_plugin("_cov") is not None and not getattr(
        session.config.option, "no_cov", False
    ):
        import importlib

        from mining_dashboard.web.views import xvb_views

        importlib.reload(xvb_views)
    global OVERVIEW, BADGES
    OVERVIEW = JSONSession(
        BINARY,
        REPO_ROOT,
        "overview-stream",
        {"operation": "_egress_badge", "args": [{"level": "ok", "leaks": 0, "label": "ok"}]},
    )
    BADGES = JSONSession(
        BINARY,
        REPO_ROOT,
        "badges-stream",
        {"operation": "recent_wallet_change", "args": [{}]},
    )
    _set_operations(NATIVES)


def pytest_unconfigure(config):
    del config
    for session in (OVERVIEW, BADGES):
        if session is not None:
            session.close()
