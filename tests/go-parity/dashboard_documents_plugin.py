import json
import os
from collections import Counter
from pathlib import Path

import pytest

pytest_plugins = ["dashboard_wizard_values_plugin"]

ROOT = Path(__file__).resolve().parents[2]
CALLS = Counter()
ERRORS = Counter()


def _fatal(*args, **kwargs):
    del args, kwargs
    raise AssertionError("reference dashboard documents used in Go mode")


def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_channel, go_documents

    os.environ.setdefault("PITHEAD_DASHBOARD_GO_BINARY", str(ROOT / "go/bin/dashboard"))
    go_documents.install()
    for original in go_documents.REFERENCE_FUNCTIONS.values():
        original.__code__ = _fatal.__code__
    call = go_channel.call

    def counted(helper, payload):
        operation = payload.get("operation", "")
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "documents":
                ERRORS[f"{operation}:{type(error).__name__}"] += 1
                if trace := os.environ.get("PITHEAD_DOCUMENTS_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{operation}:error\n")
            raise
        if helper == "documents":
            CALLS[operation] += 1
            if trace := os.environ.get("PITHEAD_DOCUMENTS_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{operation}\n")
        return value

    go_channel.call = counted


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native dashboard documents calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native dashboard documents errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
