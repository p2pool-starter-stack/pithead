import json
import os
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import FunctionType

import pytest
import pytest_asyncio

# ruff: noqa: F821

pytest_plugins = ["dashboard_polling_plugin"]

ORIGINAL = None
NATIVE = None
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()


def _modules():
    from mining_dashboard.web import server
    from mining_dashboard.web.views import views

    return views, server


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
    _pithead_assembly_fallbacks["unexpected"] += 1
    raise AssertionError("reference state assembly used in Go mode")


def _set(function):
    views, server = _modules()
    views.build_state = function
    server.build_state = function


@contextmanager
def python_operations():
    import dashboard_polling_plugin

    with dashboard_polling_plugin.python_operations():
        _set(ORIGINAL)
        try:
            yield
        finally:
            _set(NATIVE)


def python_call(*args, **kwargs):
    with python_operations():
        return ORIGINAL(*args, **kwargs)


@pytest_asyncio.fixture(autouse=True)
async def standalone_snapshot_executor(request, monkeypatch):
    if (
        os.environ.get("PITHEAD_IMPL") != "go"
        or request.module.__name__ != "tests.test_go_snapshot_interleave"
    ):
        yield
        return
    from mining_dashboard.go_state_executor import StateExecutor

    executor = StateExecutor()
    initialize = request.module.Request.__init__

    def initialize_request(instance, *args, **kwargs):
        initialize(instance, *args, **kwargs)
        instance.app["go_state_executor"] = executor

    monkeypatch.setattr(request.module.Request, "__init__", initialize_request)
    try:
        yield
    finally:
        await executor.close()


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    global ORIGINAL, NATIVE
    from mining_dashboard import go_channel, go_state

    views, _server = _modules()
    source = go_state.REFERENCE_FUNCTIONS.get("build_state", views.build_state)
    ORIGINAL = _clone(source)
    views._pithead_assembly_fallbacks = FALLBACKS
    source.__code__ = _fatal.__code__
    go_state.install()
    NATIVE = views.build_state
    _set(NATIVE)
    call = go_channel.call

    def counted(helper, payload):
        operation = payload.get("operation", "")
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "state":
                ERRORS[f"{operation}:{type(error).__name__}"] += 1
                if trace := os.environ.get("PITHEAD_ASSEMBLY_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "state":
            CALLS[operation] += 1
            if trace := os.environ.get("PITHEAD_ASSEMBLY_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{operation}\n")
        return value

    go_channel.call = counted


def pytest_sessionfinish(session):
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_state_assembly"] = [
            dict(CALLS),
            dict(ERRORS),
            dict(FALLBACKS),
        ]
    if FALLBACKS:
        session.exitstatus = 1


@pytest.hookimpl(optionalhook=True)
def pytest_testnodedown(node, error):
    del error
    if report := node.workeroutput.get("native_state_assembly"):
        for counter, values in zip((CALLS, ERRORS, FALLBACKS), report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native state assembly calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native state assembly errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected state assembly fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
