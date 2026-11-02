import json
import os
from collections import Counter
from contextlib import contextmanager
from types import FunctionType

import pytest

pytest_plugins = ["dashboard_config_meta_plugin", "dashboard_storage_plugin"]

ORIGINALS = {}
NATIVES = {}
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()
COMPATIBILITY = Counter()
_CONFIGURED = False
_SELECTED_BINARY = os.environ.get("PITHEAD_DASHBOARD_GO_BINARY")


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
    FALLBACKS["unexpected"] += 1
    raise AssertionError("reference revision storage used in Go mode")


@contextmanager
def python_operation():
    from mining_dashboard.service.workers import worker_revision_store

    for name, function in ORIGINALS.items():
        setattr(worker_revision_store, name, function)
    try:
        yield
    finally:
        for name, function in NATIVES.items():
            setattr(worker_revision_store, name, function)


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    global _CONFIGURED
    del config
    if _CONFIGURED or os.environ.get("PITHEAD_IMPL") != "go":
        return
    _CONFIGURED = True
    from mining_dashboard import go_revision_store
    from mining_dashboard.service.workers import worker_revision_store

    go_revision_store.install()
    if _SELECTED_BINARY:
        os.environ["PITHEAD_DASHBOARD_GO_BINARY"] = _SELECTED_BINARY
    worker_revision_store.FALLBACKS = FALLBACKS
    for name, source in go_revision_store.REFERENCE_FUNCTIONS.items():
        ORIGINALS[name] = _clone(source)
        source.__code__ = _fatal.__code__
        source.__defaults__ = _fatal.__defaults__
        source.__kwdefaults__ = _fatal.__kwdefaults__
        NATIVES[name] = getattr(go_revision_store, name)
        setattr(worker_revision_store, name, NATIVES[name])
    compatible = go_revision_store._compat

    def counted(name, reason, *args):
        COMPATIBILITY[f"{name}:{reason}"] += 1
        return compatible(name, reason, *args)

    go_revision_store._compat = counted
    next_compatibility = go_revision_store._compat_next

    def counted_next(reason, *args):
        COMPATIBILITY[f"next_drift:{reason}"] += 1
        return next_compatibility(reason, *args)

    go_revision_store._compat_next = counted_next


@pytest.hookimpl(trylast=True)
def pytest_sessionstart(session):
    del session
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_storage

    request = go_storage.GoConnection._request

    def counted(self, operation, **payload):
        if not operation.startswith("worker-revision-"):
            return request(self, operation, **payload)
        try:
            value = request(self, operation, **payload)
        except BaseException:
            ERRORS[operation] += 1
            raise
        CALLS[operation] += 1
        return value

    go_storage.GoConnection._request = counted


def pytest_sessionfinish(session):
    report = [dict(CALLS), dict(ERRORS), dict(FALLBACKS), dict(COMPATIBILITY)]
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_revision_store"] = report
    if FALLBACKS:
        session.exitstatus = 1


@pytest.hookimpl(optionalhook=True)
def pytest_testnodedown(node, error):
    del error
    if report := node.workeroutput.get("native_revision_store"):
        for counter, values in zip((CALLS, ERRORS, FALLBACKS, COMPATIBILITY), report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    terminalreporter.write_sep("=", "native revision storage calls " + json.dumps(dict(CALLS)))
    terminalreporter.write_line("native revision storage errors " + json.dumps(dict(ERRORS)))
    terminalreporter.write_line(
        "unexpected revision storage fallbacks " + json.dumps(dict(FALLBACKS))
    )
    terminalreporter.write_line(
        "intentional revision storage compatibility " + json.dumps(dict(COMPATIBILITY))
    )
