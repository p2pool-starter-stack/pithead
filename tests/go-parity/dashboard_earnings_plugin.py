import json
import os
import time
import uuid
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import FunctionType

import pytest
from dashboard_fleet_session import JSONSession

# ruff: noqa: F821

pytest_plugins = ["dashboard_overview_plugin"]

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get("PITHEAD_DASHBOARD_GO_BINARY", ROOT / "go/bin/dashboard"))
MODEL_OPERATIONS = (
    "xmr_per_hs_day",
    "xtm_per_hs_day",
    "tari_seconds_to_block_per_hs",
    "previous_local_day",
    "confirmed_payouts_summary",
)
VIEW_OPERATIONS = ("build_earnings", "build_earnings_vs_actual")
OPERATIONS = MODEL_OPERATIONS + VIEW_OPERATIONS
ORIGINALS = {}
REFERENCE_BODIES = {}
CALLS = Counter()
FALLBACKS = Counter()
SESSION = None


def _restore(value, marker):
    if (
        isinstance(value, dict)
        and set(value) == {marker}
        and value[marker] in ("nan", "inf", "-inf")
    ):
        return {"nan": float("nan"), "inf": float("inf"), "-inf": float("-inf")}[value[marker]]
    if isinstance(value, dict):
        return {key: _restore(item, marker) for key, item in value.items()}
    if isinstance(value, list):
        return [_restore(item, marker) for item in value]
    return value


def _run(operation, args, now=None, zone=None):
    from mining_dashboard import go_overview

    if SESSION is None:
        raise RuntimeError("Go earnings helper is unavailable")
    settings = {"now": time.time() if now is None else now}
    if zone is not None:
        settings["zone"] = zone
    request = go_overview.request(operation, args, settings)
    encoded = json.dumps(request, allow_nan=False, separators=(",", ":"))
    marker = ""
    while not marker or marker in encoded:
        marker = "__pithead_nonfinite_" + uuid.uuid4().hex
    request["nonfinite_marker"] = marker
    result = _restore(SESSION.run(request), marker)
    CALLS[operation] += 1
    if trace := os.environ.get("PITHEAD_EARNINGS_TRACE"):
        with Path(trace).open("a") as stream:
            stream.write(f"{operation}\n")
    return result


def native_xmr_per_hs_day(block_reward_atomic, network_difficulty):
    return float(_run("xmr_per_hs_day", [block_reward_atomic, network_difficulty]))


def native_xtm_per_hs_day(block_reward_xtm, network_difficulty):
    return float(_run("xtm_per_hs_day", [block_reward_xtm, network_difficulty]))


def native_tari_seconds_to_block_per_hs(network_difficulty):
    return float(_run("tari_seconds_to_block_per_hs", [network_difficulty]))


def native_previous_local_day(now):
    return tuple(_run("previous_local_day", [], now=now))


def native_confirmed_payouts_summary(
    payouts, now=None, divisor=1_000_000_000_000, unit="xmr", wallet_status=None
):
    return _run(
        "confirmed_payouts_summary",
        [payouts, divisor, unit, wallet_status],
        now=time.time() if now is None else now,
    )


def native_build_earnings(data, metrics, payouts=None, tari_payouts=None, xvb_day=None):
    return _run(
        "build_earnings",
        [data, metrics, payouts, tari_payouts, xvb_day],
        now=time.time(),
    )


def native_build_earnings_vs_actual(
    metrics, earnings, raffle_wins, now=None, expected_wins_day=None, realization=None
):
    return _run(
        "build_earnings_vs_actual",
        [metrics, earnings, raffle_wins, expected_wins_day, realization],
        now=time.time() if now is None else now,
    )


NATIVES = {
    name.removeprefix("native_"): value
    for name, value in tuple(globals().items())
    if name.startswith("native_")
}


def _modules():
    from mining_dashboard.service.xvb import earnings
    from mining_dashboard.web.views import views, xvb_views

    return earnings, xvb_views, views


def _clone(function):
    value = FunctionType(
        function.__code__,
        function.__globals__,
        function.__name__,
        function.__defaults__,
        function.__closure__,
    )
    value.__kwdefaults__ = function.__kwdefaults__
    value.__dict__.update(function.__dict__)
    return value


def _fatal(*args, **kwargs):
    del args, kwargs
    _pithead_earnings_fallbacks["unexpected"] += 1
    raise AssertionError("reference earnings operation used in Go mode")


def _set_operations(values):
    from mining_dashboard.service.notify import telegram_commands, telegram_formatters

    earnings, xvb_views, views = _modules()
    for name in MODEL_OPERATIONS:
        setattr(earnings, name, values[name])
        if hasattr(xvb_views, name):
            setattr(xvb_views, name, values[name])
        for aliases in (telegram_commands, telegram_formatters):
            if hasattr(aliases, name):
                setattr(aliases, name, values[name])
    for name in VIEW_OPERATIONS:
        setattr(xvb_views, name, values[name])
        setattr(views, name, values[name])


@contextmanager
def python_operations():
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
    import dashboard_http_plugin

    dashboard_http_plugin.BINARY = BINARY
    earnings, xvb_views, _views = _modules()
    sources = {name: getattr(earnings, name) for name in MODEL_OPERATIONS}
    sources.update({name: getattr(xvb_views, name) for name in VIEW_OPERATIONS})
    REFERENCE_BODIES.update(sources)
    ORIGINALS.update({name: _clone(function) for name, function in sources.items()})
    earnings._pithead_earnings_fallbacks = FALLBACKS
    xvb_views._pithead_earnings_fallbacks = FALLBACKS
    seen = set()
    for function in sources.values():
        if id(function) in seen:
            continue
        seen.add(id(function))
        function.__code__ = _fatal.__code__
    _set_operations(NATIVES)


@pytest.hookimpl(hookwrapper=True)
def pytest_sessionstart(session):
    yield
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    global SESSION
    SESSION = JSONSession(
        BINARY,
        ROOT,
        "overview-stream",
        {"operation": "xmr_per_hs_day", "args": [1, 1], "now": 1, "zone": "UTC"},
    )
    _set_operations(NATIVES)


def pytest_unconfigure(config):
    del config
    if SESSION is not None:
        SESSION.close()


def pytest_sessionfinish(session):
    if FALLBACKS:
        session.exitstatus = 1


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native earnings calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected earnings fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
