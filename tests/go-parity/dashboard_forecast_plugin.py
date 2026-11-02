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

pytest_plugins = ["dashboard_earnings_plugin"]

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get("PITHEAD_DASHBOARD_GO_BINARY", ROOT / "go/bin/dashboard"))
OPERATIONS = (
    "xvb_current_tier_key",
    "xvb_forecast_tier_key",
    "xvb_current_tier_reward_day",
    "xvb_expected_wins_day",
    "xvb_realization",
    "xvb_tempered_day",
    "build_xvb_calc",
)
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


def settings():
    from mining_dashboard import go_forecast

    return go_forecast.settings()


def ordered_tiers(tiers):
    from mining_dashboard import go_forecast

    return go_forecast.tiers(tiers)


def _run(operation, args, now=None):
    from mining_dashboard import go_overview

    if SESSION is None:
        raise RuntimeError("Go forecast helper is unavailable")
    clock = {"now": time.time() if now is None else now}
    request = go_overview.request(operation, args, clock)
    encoded = json.dumps(request, allow_nan=False, separators=(",", ":"))
    marker = ""
    while not marker or marker in encoded:
        marker = "__pithead_nonfinite_" + uuid.uuid4().hex
    request["nonfinite_marker"] = marker
    result = _restore(SESSION.run(request), marker)
    CALLS[operation] += 1
    if trace := os.environ.get("PITHEAD_FORECAST_TRACE"):
        with Path(trace).open("a") as stream:
            stream.write(f"{operation}\n")
    return result


def native_xvb_current_tier_key(metrics, tiers):
    return _run("xvb_current_tier_key", [metrics, ordered_tiers(tiers)])


def native_xvb_forecast_tier_key(metrics, tiers):
    return _run("xvb_forecast_tier_key", [metrics, ordered_tiers(tiers)])


def native_xvb_current_tier_reward_day(metrics, state_mgr, now=None):
    args = [metrics, ordered_tiers(state_mgr.get_tiers()), state_mgr.get_xvb_reward_estimates()]
    return _run("xvb_current_tier_reward_day", [*args, settings()], now)


def native_xvb_expected_wins_day(round_state, tier_key, tiers, now=None):
    return _run(
        "xvb_expected_wins_day",
        [round_state, tier_key, ordered_tiers(tiers), settings()],
        now,
    )


def native_xvb_realization(
    payouts, raffle_wins, xvb_day, expected_wins_day, now=None, p2pool_day=None
):
    value = _run(
        "xvb_realization",
        [payouts, raffle_wins, xvb_day, expected_wins_day, p2pool_day, settings()],
        now,
    )
    return tuple(value) if value is not None else None


def native_xvb_tempered_day(xvb_day, realization):
    return _run("xvb_tempered_day", [xvb_day, realization, settings()])


def native_build_xvb_calc(metrics, state_mgr, realization=None, now=None):
    return _run(
        "build_xvb_calc",
        [
            metrics,
            ordered_tiers(state_mgr.get_tiers()),
            state_mgr.get_xvb_round_stats(),
            state_mgr.get_xvb_reward_estimates(),
            realization,
            settings(),
        ],
        now,
    )


def native_xvb_state(
    metrics, tiers, round_state, estimate_state, payouts, wins, coeff_day, now=None
):
    value = _run(
        "xvb_state",
        [
            metrics,
            ordered_tiers(tiers),
            round_state,
            estimate_state,
            payouts,
            wins,
            coeff_day,
            settings(),
        ],
        now,
    )
    if value.get("realization") is not None:
        value["realization"] = tuple(value["realization"])
    return value


NATIVES = {
    name.removeprefix("native_"): value
    for name, value in tuple(globals().items())
    if name.startswith("native_")
}


def _modules():
    from mining_dashboard.web.views import views, xvb_calculator, xvb_views

    return xvb_views, xvb_calculator, views


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
    _pithead_forecast_fallbacks["unexpected"] += 1
    raise AssertionError("reference forecast operation used in Go mode")


def _set_operations(values):
    for module in _modules():
        for name in OPERATIONS:
            if hasattr(module, name):
                setattr(module, name, values[name])


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
    xvb_views, xvb_calculator, _views = _modules()
    sources = {
        name: getattr(xvb_calculator if name == "build_xvb_calc" else xvb_views, name)
        for name in OPERATIONS
    }
    REFERENCE_BODIES.update(sources)
    ORIGINALS.update({name: _clone(function) for name, function in sources.items()})
    for module in _modules():
        module._pithead_forecast_fallbacks = FALLBACKS
    for function in {id(value): value for value in sources.values()}.values():
        function.__code__ = _fatal.__code__
    _set_operations(NATIVES)


@pytest.hookimpl(hookwrapper=True, trylast=True)
def pytest_sessionstart(session):
    yield
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    global SESSION
    SESSION = JSONSession(
        BINARY,
        ROOT,
        "overview-stream",
        {"operation": "xvb_tempered_day", "args": [None, None, settings()], "now": 1},
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
            "=", "native forecast calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected forecast fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
