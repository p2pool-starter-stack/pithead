import inspect
import json
import os
from collections import Counter
from pathlib import Path

import pytest

pytest_plugins = ["dashboard_documents_plugin"]

ROOT = Path(__file__).resolve().parents[2]
CALLS = Counter()
ERRORS = Counter()


def _fatal(*args, **kwargs):
    del args, kwargs
    raise AssertionError("reference control HTTP policy used in Go mode")


async def _fatal_async(*args, **kwargs):
    del args, kwargs
    raise AssertionError("reference control HTTP policy used in Go mode")


def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_channel, go_control_http
    from mining_dashboard.web import server

    os.environ.setdefault("PITHEAD_DASHBOARD_GO_BINARY", str(ROOT / "go/bin/dashboard"))
    go_control_http.install(server)
    for original in go_control_http.REFERENCE_FUNCTIONS.values():
        fatal = _fatal_async if inspect.iscoroutinefunction(original) else _fatal
        original.__code__ = fatal.__code__
    call = go_channel.call

    def counted(helper, payload):
        operation = payload.get("operation", "")
        label = f"{operation}:{payload.get('route', '')}"
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "control-http":
                ERRORS[f"{label}:{type(error).__name__}"] += 1
                if trace := os.environ.get("PITHEAD_CONTROL_HTTP_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{label}:error\n")
            raise
        if helper == "control-http":
            CALLS[label] += 1
            if trace := os.environ.get("PITHEAD_CONTROL_HTTP_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{label}\n")
        return value

    go_channel.call = counted


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native control HTTP calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native control HTTP errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
