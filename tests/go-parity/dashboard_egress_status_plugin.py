import json
import os
import sys
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import FunctionType

import pytest

# ruff: noqa: F821

pytest_plugins = ["dashboard_network_plugin"]

OPERATIONS = ("firewall-status-valid", "firewall-status-result", "firewall-plan")
ORIGINALS = {}
NATIVES = {}
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()
COMPATIBILITY = Counter()
CAPTURED = []


def _module():
    from mining_dashboard.service.network import egress_status

    return egress_status


def _current():
    module = _module()
    return {
        "egress_firewall_state": module.egress_firewall_state,
        "with_firewall_state": module.with_firewall_state,
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
    _pithead_egress_status_fallbacks["unexpected"] += 1
    raise AssertionError("reference egress status policy used in Go mode")


def _set(values):
    from mining_dashboard.service.network import egress, egress_status, topology

    egress_status.egress_firewall_state = values["egress_firewall_state"]
    egress_status.with_firewall_state = values["with_firewall_state"]
    egress.with_firewall_state = values["with_firewall_state"]
    topology.with_firewall_state = values["with_firewall_state"]
    for module, name, key in CAPTURED:
        setattr(module, name, values[key])


@contextmanager
def python_operations():
    import dashboard_network_plugin

    with dashboard_network_plugin.python_operations():
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
    from mining_dashboard import go_egress_status

    sources = {
        name: go_egress_status.REFERENCE_FUNCTIONS.get(name, value)
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
    _module()._pithead_egress_status_fallbacks = FALLBACKS
    for source in sources.values():
        source.__code__ = _fatal.__code__
    go_egress_status.install()
    NATIVES.update(_current())
    _set(NATIVES)
    for name in ("_loaded_compat", "_result_compat", "_resolved_compat"):
        compatibility = getattr(go_egress_status, name)

        def compatible(reason, *args, _compatibility=compatibility, _name=name, **kwargs):
            COMPATIBILITY[f"{_name}:{reason}"] += 1
            return _compatibility(reason, *args, **kwargs)

        setattr(go_egress_status, name, compatible)


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
                if trace := os.environ.get("PITHEAD_EGRESS_STATUS_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "network" and operation in OPERATIONS:
            CALLS[operation] += 1
            if trace := os.environ.get("PITHEAD_EGRESS_STATUS_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(operation + "\n")
        return value

    go_channel.call = counted


def pytest_sessionfinish(session):
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_egress_status"] = [
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
    if report := node.workeroutput.get("native_egress_status"):
        for counter, values in zip((CALLS, ERRORS, FALLBACKS, COMPATIBILITY), report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native egress status calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native egress status errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected egress status fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
        terminalreporter.write_line(
            "intentional egress status compatibility "
            + json.dumps(dict(COMPATIBILITY), sort_keys=True)
        )
