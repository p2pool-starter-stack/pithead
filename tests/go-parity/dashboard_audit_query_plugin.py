import json
import os
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import FunctionType

import pytest

# ruff: noqa: F821

pytest_plugins = ["dashboard_audit_log_plugin"]

OPERATIONS = ("audit-filter", "audit-merge", "audit-query")
ORIGINALS = {}
NATIVES = {}
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()
COMPATIBILITY = Counter()


def _modules():
    from mining_dashboard.service import audit_service
    from mining_dashboard.web import server

    return audit_service, server


def _current():
    audit_service, server = _modules()
    return {
        "filter_log_entries": audit_service.filter_log_entries,
        "_merged_audit_entries": server._merged_audit_entries,
        "_log_filters": server._log_filters,
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
    _pithead_audit_query_fallbacks["unexpected"] += 1
    raise AssertionError("reference audit query policy used in Go mode")


def _set(values):
    audit_service, server = _modules()
    audit_service.filter_log_entries = values["filter_log_entries"]
    server._merged_audit_entries = values["_merged_audit_entries"]
    server._log_filters = values["_log_filters"]


@contextmanager
def python_operations():
    import dashboard_audit_log_plugin

    with dashboard_audit_log_plugin.python_operations():
        _set(ORIGINALS)
        try:
            yield
        finally:
            _set(NATIVES)


def python_call(operation, *args, **kwargs):
    with python_operations():
        return ORIGINALS[operation](*args, **kwargs)


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_audit_query, go_channel

    sources = {
        name: go_audit_query.REFERENCE_FUNCTIONS.get(name, function)
        for name, function in _current().items()
    }
    ORIGINALS.update({name: _clone(function) for name, function in sources.items()})
    audit_service, server = _modules()
    audit_service._pithead_audit_query_fallbacks = FALLBACKS
    server._pithead_audit_query_fallbacks = FALLBACKS
    for function in {id(value): value for value in sources.values()}.values():
        function.__code__ = _fatal.__code__
    go_audit_query.install()
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
                if trace := os.environ.get("PITHEAD_AUDIT_QUERY_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "wizard-config" and operation in OPERATIONS:
            CALLS[operation] += 1
            if trace := os.environ.get("PITHEAD_AUDIT_QUERY_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{operation}\n")
        return value

    go_channel.call = counted
    filter_compat = go_audit_query._filter_compat
    merge_compat = go_audit_query._merge_compat

    def compatible_filter(*args, **kwargs):
        COMPATIBILITY["filter"] += 1
        return filter_compat(*args, **kwargs)

    def compatible_merge(*args, **kwargs):
        COMPATIBILITY["merge"] += 1
        return merge_compat(*args, **kwargs)

    go_audit_query._filter_compat = compatible_filter
    go_audit_query._merge_compat = compatible_merge


def pytest_sessionfinish(session):
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_audit_query"] = [
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
    if report := node.workeroutput.get("native_audit_query"):
        for counter, values in zip((CALLS, ERRORS, FALLBACKS, COMPATIBILITY), report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native audit query calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native audit query errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected audit query fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
        terminalreporter.write_line(
            "intentional audit query compatibility "
            + json.dumps(dict(COMPATIBILITY), sort_keys=True)
        )
