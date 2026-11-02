import inspect
import json
import os
from collections import Counter
from contextlib import asynccontextmanager, contextmanager
from pathlib import Path
from types import FunctionType

import pytest

# ruff: noqa: F821

pytest_plugins = ["dashboard_worker_detail_plugin"]

FUNCTIONS = (
    "_parse_proxy_list_worker",
    "_parse_legacy_dict_worker",
    "_normalize_proxy_workers",
    "_parse_proxy_summary",
    "_merge_proxy_summary",
    "_merge_direct_stats",
    "_aggregate_hashrate",
    "_aggregate_window_hashrates",
    "_summary_deltas",
    "_shares_to_record",
)
METHODS = ("WorkerLifecycle.update", "WorkerProber.probe")
OPERATIONS = FUNCTIONS + METHODS
DATA_SERVICE_ALIASES = (
    "_normalize_proxy_workers",
    "_merge_proxy_summary",
    "_merge_direct_stats",
    "_aggregate_hashrate",
    "_aggregate_window_hashrates",
    "_summary_deltas",
    "_shares_to_record",
)
ORIGINALS = {}
NATIVES = {}
CALLS = Counter()
ERRORS = Counter()
FALLBACKS = Counter()


def _modules():
    from mining_dashboard.service import data_helpers, data_service, worker_probe

    return data_helpers, data_service, worker_probe


def _current():
    data_helpers, _data_service, worker_probe = _modules()
    values = {name: getattr(data_helpers, name) for name in FUNCTIONS}
    values["WorkerLifecycle.update"] = data_helpers.WorkerLifecycle.update
    values["WorkerProber.probe"] = worker_probe.WorkerProber.probe
    return values


def _sources():
    from mining_dashboard import go_polling

    if all(name in go_polling.REFERENCE_FUNCTIONS for name in OPERATIONS):
        return {name: go_polling.REFERENCE_FUNCTIONS[name] for name in OPERATIONS}
    return _current()


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
    _pithead_polling_fallbacks["unexpected"] += 1
    raise AssertionError("reference polling operation used in Go mode")


async def _fatal_async(*args, **kwargs):
    del args, kwargs
    _pithead_polling_fallbacks["unexpected"] += 1
    raise AssertionError("reference polling operation used in Go mode")


def _set_operations(values):
    data_helpers, data_service, worker_probe = _modules()
    for name in FUNCTIONS:
        setattr(data_helpers, name, values[name])
    for name in DATA_SERVICE_ALIASES:
        setattr(data_service, name, values[name])
    data_helpers.WorkerLifecycle.update = values["WorkerLifecycle.update"]
    worker_probe.WorkerProber.probe = values["WorkerProber.probe"]


@contextmanager
def python_operations():
    import dashboard_worker_detail_plugin

    with dashboard_worker_detail_plugin.python_operations():
        _set_operations(ORIGINALS)
        try:
            yield
        finally:
            _set_operations(NATIVES)


def python_call(operation, *args, **kwargs):
    with python_operations():
        return ORIGINALS[operation](*args, **kwargs)


@asynccontextmanager
async def python_async_operations():
    with python_operations():
        yield


async def python_async_call(operation, *args, **kwargs):
    async with python_async_operations():
        return await ORIGINALS[operation](*args, **kwargs)


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_channel, go_polling

    sources = _sources()
    ORIGINALS.update({name: _clone(function) for name, function in sources.items()})
    data_helpers, _data_service, worker_probe = _modules()
    data_helpers._pithead_polling_fallbacks = FALLBACKS
    worker_probe._pithead_polling_fallbacks = FALLBACKS
    for function in {id(value): value for value in sources.values()}.values():
        fatal = _fatal_async if inspect.iscoroutinefunction(function) else _fatal
        function.__code__ = fatal.__code__
    go_polling.install()
    NATIVES.update(_current())
    _set_operations(NATIVES)
    call = go_channel.call

    def counted(helper, payload):
        operation = payload.get("operation", "")
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "fleet" and operation.startswith("poll_"):
                ERRORS[f"{operation}:{type(error).__name__}"] += 1
                if trace := os.environ.get("PITHEAD_POLLING_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "fleet" and operation.startswith("poll_"):
            CALLS[operation] += 1
            if trace := os.environ.get("PITHEAD_POLLING_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{operation}\n")
        return value

    go_channel.call = counted


def pytest_sessionfinish(session):
    if FALLBACKS:
        session.exitstatus = 1


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native polling calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native polling errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "unexpected polling fallbacks " + json.dumps(dict(FALLBACKS), sort_keys=True)
        )
