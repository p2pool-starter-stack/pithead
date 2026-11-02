import json
import os
import sys
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import FunctionType

import pytest
from dashboard_network_session import NetworkSession

# ruff: noqa: F821

pytest_plugins = ["dashboard_access_log_plugin"]

OPERATIONS = ("posture", "topology-edges", "topology-nodes")
ORIGINALS = {}
NATIVES = {}
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()
COMPATIBILITY = Counter()
CAPTURED = []
SESSION = None


def _modules():
    from mining_dashboard.service.network import egress, topology, topology_graph

    return egress, topology, topology_graph


def _current():
    egress, topology, topology_graph = _modules()
    return {
        "compute_egress_posture": egress.compute_egress_posture,
        "compute_topology": topology.compute_topology,
        "topology_nodes": topology_graph.topology_nodes,
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
    _pithead_network_fallbacks["unexpected"] += 1
    raise AssertionError("reference network policy used in Go mode")


def _set(values):
    egress, topology, topology_graph = _modules()
    egress.compute_egress_posture = values["compute_egress_posture"]
    topology.compute_egress_posture = values["compute_egress_posture"]
    topology.compute_topology = values["compute_topology"]
    topology.topology_nodes = values["topology_nodes"]
    topology_graph.topology_nodes = values["topology_nodes"]
    for module, name, key in CAPTURED:
        setattr(module, name, values[key])


@contextmanager
def python_operations():
    import dashboard_access_log_plugin

    with dashboard_access_log_plugin.python_operations():
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
    from mining_dashboard import go_channel, go_network

    sources = {
        name: go_network.REFERENCE_FUNCTIONS.get(name, value) for name, value in _current().items()
    }
    originals = {name: _clone(source) for name, source in sources.items()}
    ORIGINALS.update(originals)
    for module in tuple(sys.modules.values()):
        if module is None:
            continue
        namespace = getattr(module, "__dict__", {})
        for name, source in sources.items():
            for attribute, value in tuple(namespace.items()):
                if value is source:
                    CAPTURED.append((module, attribute, name))
    for module in _modules():
        module._pithead_network_fallbacks = FALLBACKS
    for source in sources.values():
        source.__code__ = _fatal.__code__
    go_network.install()
    NATIVES.update(_current())
    _set(NATIVES)
    call = go_channel.call

    def counted(helper, payload):
        operation = payload.get("operation", "")
        try:
            value = (
                SESSION.call(payload)
                if helper == "network" and SESSION is not None
                else call(helper, payload)
            )
        except Exception as error:
            if helper == "network" and operation in OPERATIONS:
                ERRORS[f"{operation}:{type(error).__name__}"] += 1
                if trace := os.environ.get("PITHEAD_NETWORK_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "network" and operation in OPERATIONS:
            CALLS[operation] += 1
            if trace := os.environ.get("PITHEAD_NETWORK_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(operation + "\n")
        return value

    go_channel.call = counted
    compatibility = go_network._compat
    topology_compatibility = go_network._topology_compat

    def compatible(name, reason, *args, **kwargs):
        COMPATIBILITY[f"{name}:{reason}"] += 1
        return compatibility(name, reason, *args, **kwargs)

    def topology_compatible(reason, *args, **kwargs):
        COMPATIBILITY[f"compute_topology:{reason}"] += 1
        return topology_compatibility(reason, *args, **kwargs)

    go_network._compat = compatible
    go_network._topology_compat = topology_compatible


@pytest.hookimpl(trylast=True)
def pytest_sessionstart(session):
    del session
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_channel

    global SESSION
    SESSION = NetworkSession(go_channel.binary(), Path(__file__).resolve().parents[2])


def pytest_unconfigure(config):
    del config
    if SESSION is not None:
        SESSION.close()


def pytest_sessionfinish(session):
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_network"] = [
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
    if report := node.workeroutput.get("native_network"):
        for counter, values in zip((CALLS, ERRORS, FALLBACKS, COMPATIBILITY), report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native network calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native network errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected network fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
        terminalreporter.write_line(
            "intentional network compatibility " + json.dumps(dict(COMPATIBILITY), sort_keys=True)
        )
