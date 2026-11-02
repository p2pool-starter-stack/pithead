import json
import os
import sys
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import FunctionType

import pytest

# ruff: noqa: F821

pytest_plugins = ["dashboard_egress_status_plugin"]

OPERATIONS = ("control-outcomes",)
ORIGINALS = {}
NATIVES = {}
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()
COMPATIBILITY = Counter()
CAPTURED = []


def _modules():
    from mining_dashboard.client import xmrig_client
    from mining_dashboard.service import data_audit

    return xmrig_client, data_audit


def _current():
    xmrig_client, data_audit = _modules()
    return {
        "parse_worker_control_status": xmrig_client.parse_worker_control_status,
        "_terminal_control_history": data_audit._terminal_control_history,
        "_reconcile_worker_config": data_audit.DataAuditMixin._reconcile_worker_config,
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
    _pithead_control_outcome_fallbacks["unexpected"] += 1
    raise AssertionError("reference control outcome policy used in Go mode")


def _set(values):
    from mining_dashboard.client import xmrig_client
    from mining_dashboard.service import data_audit
    from mining_dashboard.service.workers import worker_refresh

    parser = values["parse_worker_control_status"]
    xmrig_client.parse_worker_control_status = parser
    data_audit.parse_worker_control_status = parser
    worker_refresh.parse_worker_control_status = parser
    data_audit._terminal_control_history = values["_terminal_control_history"]
    data_audit.DataAuditMixin._reconcile_worker_config = values["_reconcile_worker_config"]
    for module, name, key in CAPTURED:
        setattr(module, name, values[key])


@contextmanager
def python_operations():
    import dashboard_egress_status_plugin

    with dashboard_egress_status_plugin.python_operations():
        _set(ORIGINALS)
        try:
            yield
        finally:
            _set(NATIVES)


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_control_outcomes

    sources = {
        name: go_control_outcomes.REFERENCE_FUNCTIONS.get(name, value)
        for name, value in _current().items()
    }
    ORIGINALS.update({name: _clone(source) for name, source in sources.items()})
    for module in tuple(sys.modules.values()):
        if module is None:
            continue
        namespace = getattr(module, "__dict__", {})
        for name, source in sources.items():
            for attribute, value in tuple(namespace.items()):
                if value is source:
                    CAPTURED.append((module, attribute, name))
    xmrig_client, data_audit = _modules()
    xmrig_client._pithead_control_outcome_fallbacks = FALLBACKS
    data_audit._pithead_control_outcome_fallbacks = FALLBACKS
    for source in sources.values():
        source.__code__ = _fatal.__code__
    go_control_outcomes.install()
    NATIVES.update(_current())
    _set(NATIVES)
    for name in ("_current_compat", "_entry_compat", "_history_compat", "_reconcile_compat"):
        compatibility = getattr(go_control_outcomes, name)

        def compatible(reason, *args, _compatibility=compatibility, _name=name, **kwargs):
            COMPATIBILITY[f"{_name}:{reason}"] += 1
            return _compatibility(reason, *args, **kwargs)

        setattr(go_control_outcomes, name, compatible)


@pytest.hookimpl(trylast=True)
def pytest_sessionstart(session):
    del session
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_channel

    call = go_channel.call

    def counted(helper, payload):
        operation = payload.get("operation", "")
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "network" and operation in OPERATIONS:
                ERRORS[f"{operation}:{type(error).__name__}"] += 1
                if trace := os.environ.get("PITHEAD_CONTROL_OUTCOME_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "network" and operation in OPERATIONS:
            CALLS[operation] += 1
            if trace := os.environ.get("PITHEAD_CONTROL_OUTCOME_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(operation + "\n")
        return value

    go_channel.call = counted


def pytest_sessionfinish(session):
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_control_outcomes"] = [
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
    if report := node.workeroutput.get("native_control_outcomes"):
        for counter, values in zip((CALLS, ERRORS, FALLBACKS, COMPATIBILITY), report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native control outcome calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native control outcome errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected control outcome fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
        terminalreporter.write_line(
            "intentional control outcome compatibility "
            + json.dumps(dict(COMPATIBILITY), sort_keys=True)
        )
