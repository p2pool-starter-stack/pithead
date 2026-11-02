import json
import os
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import FunctionType

import pytest

# ruff: noqa: F821

pytest_plugins = ["dashboard_rigforge_plugin"]

ORIGINAL = None
NATIVE = None
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()
COMPATIBILITY = Counter()
OPERATION = "poll_preserve_reports"


def _module():
    from mining_dashboard.service.workers import worker_refresh

    return worker_refresh


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
    _pithead_preserve_fallbacks["unexpected"] += 1
    raise AssertionError("reference report preservation used in Go mode")


def _set(function):
    _module().preserve_newer_reports = function


@contextmanager
def python_operations():
    import dashboard_rigforge_plugin

    with dashboard_rigforge_plugin.python_operations():
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
    from mining_dashboard import go_channel, go_preserve

    worker_refresh = _module()
    source = go_preserve.REFERENCE_FUNCTIONS.get(
        "preserve_newer_reports", worker_refresh.preserve_newer_reports
    )
    ORIGINAL = _clone(source)
    worker_refresh._pithead_preserve_fallbacks = FALLBACKS
    source.__code__ = _fatal.__code__
    go_preserve.install()
    NATIVE = worker_refresh.preserve_newer_reports
    _set(NATIVE)
    provider = go_preserve._preserve_with_age_provider

    def compatible(*args, **kwargs):
        COMPATIBILITY["feed_age"] += 1
        return provider(*args, **kwargs)

    go_preserve._preserve_with_age_provider = compatible
    call = go_channel.call

    def counted(helper, payload):
        operation = payload.get("operation", "")
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "fleet" and operation == OPERATION:
                ERRORS[type(error).__name__] += 1
                if trace := os.environ.get("PITHEAD_PRESERVE_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "fleet" and operation == OPERATION:
            CALLS[operation] += 1
            if isinstance(value, dict) and isinstance(value.get("error"), dict):
                ERRORS[f"inner:{value['error'].get('kind', 'invalid')}"] += 1
            if trace := os.environ.get("PITHEAD_PRESERVE_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{operation}\n")
        return value

    go_channel.call = counted


def pytest_sessionfinish(session):
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_report_preservation"] = [
            dict(CALLS),
            dict(ERRORS),
            dict(FALLBACKS),
            dict(COMPATIBILITY),
        ]
    if FALLBACKS:
        session.exitstatus = 1


@pytest.hookimpl(optionalhook=True)
def pytest_testnodedown(node, error):
    del error
    if report := node.workeroutput.get("native_report_preservation"):
        for counter, values in zip((CALLS, ERRORS, FALLBACKS, COMPATIBILITY), report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native report preservation calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native report preservation errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected report preservation fallbacks "
            + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
        terminalreporter.write_line(
            "intentional report preservation compatibility "
            + json.dumps(dict(COMPATIBILITY), sort_keys=True)
        )
