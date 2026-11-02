import json
import os
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import FunctionType

import pytest

# ruff: noqa: F821

pytest_plugins = ["dashboard_preserve_plugin"]

OPERATIONS = (
    "leaf_paths",
    "approval_paths",
    "confirmed_paths",
    "missing_default_paths",
    "last_apply_state",
    "config_version_metadata",
    "editor_metadata",
)
ORIGINALS = {}
NATIVES = {}
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()
COMPATIBILITY = Counter()


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
    _pithead_editor_fallbacks["unexpected"] += 1
    raise AssertionError("reference editor metadata used in Go mode")


def _module():
    from mining_dashboard.service import config_operations

    return config_operations


def _set(values):
    module = _module()
    for name in OPERATIONS:
        setattr(module, name, values[name])


@contextmanager
def python_operations():
    import dashboard_preserve_plugin

    with dashboard_preserve_plugin.python_operations():
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
    from mining_dashboard import go_channel, go_editor

    module = _module()
    sources = {
        name: go_editor.REFERENCE_FUNCTIONS.get(name, getattr(module, name)) for name in OPERATIONS
    }
    ORIGINALS.update({name: _clone(function) for name, function in sources.items()})
    module._pithead_editor_fallbacks = FALLBACKS
    for function in {id(value): value for value in sources.values()}.values():
        function.__code__ = _fatal.__code__
    go_editor.install()
    for name in ("_with_providers", "_with_getter", "_with_version_provider"):
        provider = getattr(go_editor, name)

        def compatible(*args, _name=name, _provider=provider, **kwargs):
            COMPATIBILITY[_name.removeprefix("_with_")] += 1
            return _provider(*args, **kwargs)

        setattr(go_editor, name, compatible)
    NATIVES.update({name: getattr(module, name) for name in OPERATIONS})
    _set(NATIVES)
    call = go_channel.call

    def counted(helper, payload):
        operation = payload.get("operation", "")
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "wizard-config" and operation.startswith("editor-"):
                ERRORS[f"{operation}:{type(error).__name__}"] += 1
                if trace := os.environ.get("PITHEAD_EDITOR_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "wizard-config" and operation.startswith("editor-"):
            CALLS[operation] += 1
            if trace := os.environ.get("PITHEAD_EDITOR_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{operation}\n")
        return value

    go_channel.call = counted


def pytest_sessionfinish(session):
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_editor_metadata"] = [
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
    if report := node.workeroutput.get("native_editor_metadata"):
        for counter, values in zip((CALLS, ERRORS, FALLBACKS, COMPATIBILITY), report, strict=True):
            counter.update(values)


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native editor metadata calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native editor metadata errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected editor metadata fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
        terminalreporter.write_line(
            "intentional editor compatibility " + json.dumps(dict(COMPATIBILITY), sort_keys=True)
        )
