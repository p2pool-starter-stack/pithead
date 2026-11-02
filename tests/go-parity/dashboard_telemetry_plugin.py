import json
import os
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import FunctionType

import pytest

# ruff: noqa: F821

pytest_plugins = ["dashboard_editor_plugin"]

ORIGINAL = None
NATIVE = None
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()
OPERATIONS = (
    "poll_telemetry_hourly",
    "poll_telemetry_network",
    "poll_telemetry_worker_due",
    "poll_telemetry_workers",
)


def _class():
    from mining_dashboard.service.data_service import DataService

    return DataService


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
    _pithead_telemetry_fallbacks["unexpected"] += 1
    raise AssertionError("reference telemetry planner used in Go mode")


def _set(function):
    _class()._telemetry_plan = function


@contextmanager
def python_operations():
    import dashboard_editor_plugin

    with dashboard_editor_plugin.python_operations():
        _set(ORIGINAL)
        try:
            yield
        finally:
            _set(NATIVE)


def python_call(service, phase, args):
    with python_operations():
        return ORIGINAL(service, phase, args)


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    global ORIGINAL, NATIVE
    from mining_dashboard import go_channel, go_polling
    from mining_dashboard.service import telemetry_capture

    service = _class()
    source = go_polling.REFERENCE_FUNCTIONS.get("telemetry_plan", service._telemetry_plan)
    ORIGINAL = _clone(source)
    telemetry_capture._pithead_telemetry_fallbacks = FALLBACKS
    source.__code__ = _fatal.__code__
    go_polling.install()
    NATIVE = service._telemetry_plan
    _set(NATIVE)
    call = go_channel.call

    def counted(helper, payload):
        operation = payload.get("operation", "")
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "fleet" and operation in OPERATIONS:
                ERRORS[f"{operation}:{type(error).__name__}"] += 1
                if trace := os.environ.get("PITHEAD_TELEMETRY_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "fleet" and operation in OPERATIONS:
            CALLS[operation] += 1
            if trace := os.environ.get("PITHEAD_TELEMETRY_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{operation}\n")
        return value

    go_channel.call = counted


def pytest_sessionfinish(session):
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_telemetry"] = [
            dict(CALLS),
            dict(ERRORS),
            dict(FALLBACKS),
        ]
    if FALLBACKS:
        session.exitstatus = 1


@pytest.hookimpl(optionalhook=True)
def pytest_testnodedown(node, error):
    del error
    if report := node.workeroutput.get("native_telemetry"):
        for counter, values in zip((CALLS, ERRORS, FALLBACKS), report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native telemetry calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native telemetry errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected telemetry fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
