import json
import os
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import FunctionType

import pytest

# ruff: noqa: F821

pytest_plugins = ["dashboard_telemetry_plugin"]

OPERATIONS = ("audit-diff", "audit-unexplained")
ORIGINALS = {}
NATIVES = {}
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()


def _modules():
    from mining_dashboard.service import data_audit, data_helpers

    return data_helpers, data_audit


def _current():
    data_helpers, data_audit = _modules()
    return {
        "_diff_config_keys": data_helpers._diff_config_keys,
        "_unexplained_config_keys": data_audit._unexplained_config_keys,
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
    _pithead_host_audit_fallbacks["unexpected"] += 1
    raise AssertionError("reference host audit policy used in Go mode")


def _set(values):
    data_helpers, data_audit = _modules()
    data_helpers._diff_config_keys = values["_diff_config_keys"]
    data_audit._diff_config_keys = values["_diff_config_keys"]
    data_audit._unexplained_config_keys = values["_unexplained_config_keys"]


@contextmanager
def python_operations():
    import dashboard_telemetry_plugin

    with dashboard_telemetry_plugin.python_operations():
        _set(ORIGINALS)
        try:
            yield
        finally:
            _set(NATIVES)


def python_call(operation, *args):
    with python_operations():
        return ORIGINALS[operation](*args)


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
    data_helpers, data_audit = _modules()
    data_helpers._pithead_host_audit_fallbacks = FALLBACKS
    data_audit._pithead_host_audit_fallbacks = FALLBACKS
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
                if trace := os.environ.get("PITHEAD_HOST_AUDIT_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "wizard-config" and operation in OPERATIONS:
            CALLS[operation] += 1
            if trace := os.environ.get("PITHEAD_HOST_AUDIT_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{operation}\n")
        return value

    go_channel.call = counted


def pytest_sessionfinish(session):
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_host_audit"] = [
            dict(CALLS),
            dict(ERRORS),
            dict(FALLBACKS),
        ]
    if FALLBACKS:
        session.exitstatus = 1


@pytest.hookimpl(optionalhook=True)
def pytest_testnodedown(node, error):
    del error
    if report := node.workeroutput.get("native_host_audit"):
        for counter, values in zip((CALLS, ERRORS, FALLBACKS), report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native host audit calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native host audit errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected host audit fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
