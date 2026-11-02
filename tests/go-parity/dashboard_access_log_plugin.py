import json
import os
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import FunctionType

import pytest

# ruff: noqa: F821

pytest_plugins = ["dashboard_audit_query_plugin"]

OPERATIONS = ("audit-access",)
ORIGINALS = {}
NATIVES = {}
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()
COMPATIBILITY = Counter()


def _module():
    from mining_dashboard.service import audit_service

    return audit_service


def _current():
    return {"access_summary": _module().access_summary}


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
    _pithead_access_log_fallbacks["unexpected"] += 1
    raise AssertionError("reference access log policy used in Go mode")


def _set(values):
    _module().access_summary = values["access_summary"]


@contextmanager
def python_operations():
    import dashboard_audit_query_plugin

    with dashboard_audit_query_plugin.python_operations():
        _set(ORIGINALS)
        try:
            yield
        finally:
            _set(NATIVES)


def python_call(*args, **kwargs):
    with python_operations():
        return ORIGINALS["access_summary"](*args, **kwargs)


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_access_log, go_channel

    source = go_access_log.REFERENCE_FUNCTIONS.get("access_summary", _module().access_summary)
    ORIGINALS["access_summary"] = _clone(source)
    audit_service = _module()
    audit_service._pithead_access_log_fallbacks = FALLBACKS
    source.__code__ = _fatal.__code__
    go_access_log.install()
    NATIVES.update(_current())
    _set(NATIVES)
    call = go_channel.call

    def counted(helper, payload):
        operation = payload.get("operation", "")
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "wizard-config" and operation in OPERATIONS:
                ERRORS[f"{operation}:{type(error).__name__}"] += 1
                if trace := os.environ.get("PITHEAD_ACCESS_LOG_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "wizard-config" and operation in OPERATIONS:
            CALLS[operation] += 1
            if trace := os.environ.get("PITHEAD_ACCESS_LOG_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{operation}\n")
        return value

    go_channel.call = counted
    compatibility = go_access_log._access_compat

    def compatible(reason, *args, **kwargs):
        COMPATIBILITY[reason] += 1
        return compatibility(reason, *args, **kwargs)

    go_access_log._access_compat = compatible


def pytest_sessionfinish(session):
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_access_log"] = [
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
    if report := node.workeroutput.get("native_access_log"):
        for counter, values in zip((CALLS, ERRORS, FALLBACKS, COMPATIBILITY), report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native access log calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native access log errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected access log fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
        terminalreporter.write_line(
            "intentional access log compatibility "
            + json.dumps(dict(COMPATIBILITY), sort_keys=True)
        )
