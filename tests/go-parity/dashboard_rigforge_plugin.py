import json
import os
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import FunctionType

import pytest

# ruff: noqa: F821

pytest_plugins = ["dashboard_assembly_plugin"]

ORIGINAL = None
NATIVE = None
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()
OPERATIONS = {"poll_parse_rigforge", "poll_merge_rigforge_stats"}


def _modules():
    from mining_dashboard.client import xmrig_client
    from mining_dashboard.service import data_helpers
    from mining_dashboard.service.workers import worker_refresh

    return xmrig_client, data_helpers, worker_refresh


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
    _pithead_rigforge_fallbacks["unexpected"] += 1
    raise AssertionError("reference RigForge parser used in Go mode")


def _set(function):
    for module in _modules():
        module.parse_rigforge = function


@contextmanager
def python_operations():
    import dashboard_assembly_plugin

    with dashboard_assembly_plugin.python_operations():
        _set(ORIGINAL)
        try:
            yield
        finally:
            _set(NATIVE)


def python_call(*args, **kwargs):
    with python_operations():
        return ORIGINAL(*args, **kwargs)


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    global ORIGINAL, NATIVE
    from mining_dashboard import go_channel, go_rigforge

    xmrig_client, _data_helpers, _worker_refresh = _modules()
    source = go_rigforge.REFERENCE_FUNCTIONS.get("parse_rigforge", xmrig_client.parse_rigforge)
    ORIGINAL = _clone(source)
    xmrig_client._pithead_rigforge_fallbacks = FALLBACKS
    source.__code__ = _fatal.__code__
    go_rigforge.install()
    NATIVE = xmrig_client.parse_rigforge
    _set(NATIVE)
    call = go_channel.call

    def counted(helper, payload):
        operation = payload.get("operation", "")
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "fleet" and operation in OPERATIONS:
                ERRORS[f"{operation}:{type(error).__name__}"] += 1
                if trace := os.environ.get("PITHEAD_RIGFORGE_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "fleet" and operation in OPERATIONS:
            CALLS[operation] += 1
            if trace := os.environ.get("PITHEAD_RIGFORGE_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{operation}\n")
        return value

    go_channel.call = counted


def pytest_sessionfinish(session):
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_rigforge"] = [
            dict(CALLS),
            dict(ERRORS),
            dict(FALLBACKS),
        ]
    if FALLBACKS:
        session.exitstatus = 1


@pytest.hookimpl(optionalhook=True)
def pytest_testnodedown(node, error):
    del error
    if report := node.workeroutput.get("native_rigforge"):
        for counter, values in zip((CALLS, ERRORS, FALLBACKS), report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native RigForge parser calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native RigForge parser errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected RigForge parser fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
