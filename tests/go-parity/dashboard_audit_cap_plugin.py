import json
import os
from collections import Counter
from types import FunctionType

import pytest

ORIGINALS = {}
CALLS = Counter()
SELECTIONS = Counter()
ERRORS = Counter()
COMPATIBILITY = Counter()
FALLBACKS = Counter()
_pithead_audit_cap_fallbacks = FALLBACKS
_CONFIGURED = False
pytest_plugins = ["dashboard_control_outcomes_plugin"]


def _modules():
    from mining_dashboard import go_audit_cap
    from mining_dashboard.service import data_audit
    from mining_dashboard.service.workers import worker_change_audit

    return go_audit_cap, data_audit, worker_change_audit


def _fatal(*args, **kwargs):
    del args, kwargs
    _pithead_audit_cap_fallbacks["unexpected"] += 1
    raise AssertionError("reference audit cap policy used in Go mode")


def _clone(function):
    value = FunctionType(
        function.__code__,
        function.__globals__,
        function.__name__,
        function.__defaults__,
        function.__closure__,
    )
    value.__kwdefaults__ = function.__kwdefaults__
    return value


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    global _CONFIGURED
    del config
    if _CONFIGURED or os.environ.get("PITHEAD_IMPL") != "go":
        return
    _CONFIGURED = True
    go_audit_cap, data_audit, worker_change_audit = _modules()
    go_audit_cap.install()
    ORIGINALS.update(
        {name: _clone(function) for name, function in go_audit_cap.REFERENCE_FUNCTIONS.items()}
    )
    worker_change_audit._pithead_audit_cap_fallbacks = FALLBACKS
    data_audit._pithead_audit_cap_fallbacks = FALLBACKS
    for function in go_audit_cap.REFERENCE_FUNCTIONS.values():
        function.__code__ = _fatal.__code__
        function.__defaults__ = _fatal.__defaults__
        function.__kwdefaults__ = _fatal.__kwdefaults__
    for name, module in (
        ("_names_full", worker_change_audit),
        ("_count_policy", data_audit),
    ):
        function = getattr(module, name)

        def selected(*args, _function=function, _name=name, **kwargs):
            SELECTIONS[_name] += 1
            return _function(*args, **kwargs)

        setattr(module, name, selected)
    for name in ("_names_compat", "_count_compat"):
        function = getattr(go_audit_cap, name)

        def compatible(reason, *args, _function=function, _name=name, **kwargs):
            COMPATIBILITY[f"{_name}:{reason}"] += 1
            return _function(reason, *args, **kwargs)

        setattr(go_audit_cap, name, compatible)


@pytest.hookimpl(trylast=True)
def pytest_sessionstart(session):
    del session
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    go_audit_cap, _data_audit, _worker_change_audit = _modules()
    if hasattr(go_audit_cap.go_channel.call, "_pithead_audit_cap_counted"):
        return
    call = go_audit_cap.go_channel.call

    def counted(helper, request):
        if request.get("operation") == "audit-cap-policy":
            try:
                result = call(helper, request)
            except BaseException:
                ERRORS["audit-cap-policy"] += 1
                raise
            CALLS["audit-cap-policy"] += 1
            return result
        return call(helper, request)

    counted._pithead_audit_cap_counted = True
    go_audit_cap.go_channel.call = counted


def pytest_sessionfinish(session):
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_audit_cap"] = [
            dict(CALLS),
            dict(SELECTIONS),
            dict(ERRORS),
            dict(COMPATIBILITY),
            dict(FALLBACKS),
        ]
    if FALLBACKS:
        session.exitstatus = 1


@pytest.hookimpl(optionalhook=True)
def pytest_testnodedown(node, error):
    del error
    if report := node.workeroutput.get("native_audit_cap"):
        counters = (CALLS, SELECTIONS, ERRORS, COMPATIBILITY, FALLBACKS)
        for counter, values in zip(counters, report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    terminalreporter.write_sep("=", f"native audit cap plan calls {json.dumps(dict(CALLS))}")
    terminalreporter.write_line(f"native audit cap selections {json.dumps(dict(SELECTIONS))}")
    terminalreporter.write_line(f"native audit cap errors {json.dumps(dict(ERRORS))}")
    terminalreporter.write_line(f"unexpected audit cap fallbacks {json.dumps(dict(FALLBACKS))}")
    terminalreporter.write_line(
        f"intentional audit cap compatibility {json.dumps(dict(COMPATIBILITY))}"
    )
