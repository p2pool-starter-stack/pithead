import json
import os
from collections import Counter
from contextlib import contextmanager
from types import FunctionType

import pytest

pytest_plugins = ["dashboard_audit_cap_plugin"]

ORIGINALS = {}
NATIVES = {}
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()
COMPATIBILITY = Counter()
_pithead_config_meta_fallbacks = FALLBACKS
_CONFIGURED = False


def _modules():
    from mining_dashboard.client import rig_config_meta, xmrig_client
    from mining_dashboard.service.workers import worker_change_audit

    return rig_config_meta, xmrig_client, worker_change_audit


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
    _pithead_config_meta_fallbacks["unexpected"] += 1
    raise AssertionError("reference config metadata policy used in Go mode")


def _set(function):
    for module in _modules():
        module.parse_config_meta = function


@contextmanager
def python_operation():
    _set(ORIGINALS["parse_config_meta"])
    try:
        yield
    finally:
        _set(NATIVES["parse_config_meta"])


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    global _CONFIGURED
    del config
    if _CONFIGURED or os.environ.get("PITHEAD_IMPL") != "go":
        return
    _CONFIGURED = True
    from mining_dashboard import go_config_meta

    go_config_meta.install()
    source = go_config_meta.REFERENCE_FUNCTIONS["parse_config_meta"]
    ORIGINALS["parse_config_meta"] = _clone(source)
    for module in _modules():
        module._pithead_config_meta_fallbacks = FALLBACKS
    source.__code__ = _fatal.__code__
    source.__defaults__ = _fatal.__defaults__
    source.__kwdefaults__ = _fatal.__kwdefaults__
    NATIVES["parse_config_meta"] = go_config_meta.parse_config_meta
    _set(NATIVES["parse_config_meta"])
    compatibility = go_config_meta._compat

    def compatible(reason, meta):
        COMPATIBILITY[reason] += 1
        return compatibility(reason, meta)

    go_config_meta._compat = compatible


@pytest.hookimpl(trylast=True)
def pytest_sessionstart(session):
    del session
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_channel

    call = go_channel.call

    def counted(helper, payload):
        if helper != "fleet" or payload.get("operation") != "config_meta_policy":
            return call(helper, payload)
        try:
            value = call(helper, payload)
        except BaseException:
            ERRORS["config_meta_policy"] += 1
            raise
        CALLS["config_meta_policy"] += 1
        return value

    go_channel.call = counted


def pytest_sessionfinish(session):
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_config_meta"] = [
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
    if report := node.workeroutput.get("native_config_meta"):
        for counter, values in zip((CALLS, ERRORS, FALLBACKS, COMPATIBILITY), report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    terminalreporter.write_sep("=", "native config metadata calls " + json.dumps(dict(CALLS)))
    terminalreporter.write_line("native config metadata errors " + json.dumps(dict(ERRORS)))
    terminalreporter.write_line(
        "unexpected config metadata fallbacks " + json.dumps(dict(FALLBACKS))
    )
    terminalreporter.write_line(
        "intentional config metadata compatibility " + json.dumps(dict(COMPATIBILITY))
    )
