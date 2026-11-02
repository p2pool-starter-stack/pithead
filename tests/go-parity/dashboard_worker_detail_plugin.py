import json
import os
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import FunctionType

import pytest

# ruff: noqa: F821

pytest_plugins = ["dashboard_forecast_plugin", "dashboard_worker_http_plugin"]

ROOT = Path(__file__).resolve().parents[2]
OPERATIONS = (
    "build_worker_detail",
    "config_drift",
    "_has_unsettled_apply",
    "build_worker_hashrate_history",
    "config_origin",
)
ORIGINALS = {}
REFERENCE_BODIES = {}
NATIVES = {}
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()


def _modules():
    from mining_dashboard.client import rig_config_meta
    from mining_dashboard.web import server
    from mining_dashboard.web.views import worker_detail

    return worker_detail, rig_config_meta, server


def _sources():
    from mining_dashboard import go_worker_detail

    if all(name in go_worker_detail.REFERENCE_FUNCTIONS for name in OPERATIONS):
        return {name: go_worker_detail.REFERENCE_FUNCTIONS[name] for name in OPERATIONS}
    worker_detail, rig_config_meta, _server = _modules()
    return {
        "build_worker_detail": worker_detail.build_worker_detail,
        "config_drift": worker_detail.config_drift,
        "_has_unsettled_apply": worker_detail._has_unsettled_apply,
        "build_worker_hashrate_history": worker_detail.build_worker_hashrate_history,
        "config_origin": rig_config_meta.config_origin,
    }


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
    _pithead_worker_detail_fallbacks["unexpected"] += 1
    raise AssertionError("reference worker detail operation used in Go mode")


def _set_operations(values):
    worker_detail, rig_config_meta, server = _modules()
    for name in OPERATIONS:
        if name == "config_origin":
            rig_config_meta.config_origin = values[name]
            worker_detail.config_origin = values[name]
        else:
            setattr(worker_detail, name, values[name])
    server.build_worker_detail = values["build_worker_detail"]


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
    from mining_dashboard import go_channel, go_worker_detail

    sources = _sources()
    REFERENCE_BODIES.update(sources)
    ORIGINALS.update({name: _clone(function) for name, function in sources.items()})
    worker_detail, rig_config_meta, _server = _modules()
    worker_detail._pithead_worker_detail_fallbacks = FALLBACKS
    rig_config_meta._pithead_worker_detail_fallbacks = FALLBACKS
    for function in {id(value): value for value in sources.values()}.values():
        function.__code__ = _fatal.__code__
    go_worker_detail.install()
    NATIVES.update({name: getattr(go_worker_detail, name) for name in OPERATIONS})
    _set_operations(NATIVES)
    call = go_channel.call

    def counted(helper, payload):
        operation = payload.get("operation", "")
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "fleet" and operation in OPERATIONS:
                ERRORS[f"{operation}:{type(error).__name__}"] += 1
                if trace := os.environ.get("PITHEAD_WORKER_DETAIL_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "fleet" and operation in OPERATIONS:
            CALLS[operation] += 1
            if trace := os.environ.get("PITHEAD_WORKER_DETAIL_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{operation}\n")
        return value

    go_channel.call = counted


def pytest_sessionfinish(session):
    if FALLBACKS:
        session.exitstatus = 1


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native worker detail calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native worker detail errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected worker detail fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
