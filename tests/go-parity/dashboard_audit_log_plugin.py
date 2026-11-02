import json
import os
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import FunctionType

import pytest

# ruff: noqa: F821

pytest_plugins = ["dashboard_host_audit_plugin"]

OPERATIONS = ("audit-recent", "audit-mirror")
ORIGINALS = {}
NATIVES = {}
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()
COMPATIBILITY = Counter()


def _modules():
    from mining_dashboard.service import audit_service, data_audit

    return audit_service, data_audit


def _current():
    audit_service, data_audit = _modules()
    return {
        "recent_changes": audit_service.recent_changes,
        "_control_audit_rows": data_audit._control_audit_rows,
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
    _pithead_audit_log_fallbacks["unexpected"] += 1
    raise AssertionError("reference audit log policy used in Go mode")


def _set(values):
    audit_service, data_audit = _modules()
    audit_service.recent_changes = values["recent_changes"]
    data_audit._control_audit_rows = values["_control_audit_rows"]


@contextmanager
def python_operations():
    import dashboard_host_audit_plugin

    from mining_dashboard import go_editor

    with dashboard_host_audit_plugin.python_operations():
        provider = go_editor.PROVIDERS.get("audit_provider")
        _set(ORIGINALS)
        if provider is NATIVES.get("recent_changes"):
            go_editor.PROVIDERS["audit_provider"] = ORIGINALS["recent_changes"]
        try:
            yield
        finally:
            _set(NATIVES)
            if "audit_provider" in go_editor.PROVIDERS:
                go_editor.PROVIDERS["audit_provider"] = provider


def python_call(operation, *args, **kwargs):
    with python_operations():
        return ORIGINALS[operation](*args, **kwargs)


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_channel, go_polling

    sources = {
        name: go_polling.REFERENCE_FUNCTIONS.get(name, function)
        for name, function in _current().items()
    }
    ORIGINALS.update({name: _clone(function) for name, function in sources.items()})
    audit_service, data_audit = _modules()
    audit_service._pithead_audit_log_fallbacks = FALLBACKS
    data_audit._pithead_audit_log_fallbacks = FALLBACKS
    for function in {id(value): value for value in sources.values()}.values():
        function.__code__ = _fatal.__code__
    go_polling.install()
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
                if trace := os.environ.get("PITHEAD_AUDIT_LOG_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "wizard-config" and operation in OPERATIONS:
            CALLS[operation] += 1
            if trace := os.environ.get("PITHEAD_AUDIT_LOG_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{operation}\n")
        return value

    go_channel.call = counted
    compatibility = go_polling._audit_mirror_with_reader

    def compatible(entries):
        COMPATIBILITY["replaced-reader"] += 1
        return compatibility(entries)

    go_polling._audit_mirror_with_reader = compatible


def pytest_sessionfinish(session):
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_audit_log"] = [
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
    if report := node.workeroutput.get("native_audit_log"):
        for counter, values in zip((CALLS, ERRORS, FALLBACKS, COMPATIBILITY), report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native audit log calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native audit log errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected audit log fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
        terminalreporter.write_line(
            "intentional audit log compatibility " + json.dumps(dict(COMPATIBILITY), sort_keys=True)
        )
