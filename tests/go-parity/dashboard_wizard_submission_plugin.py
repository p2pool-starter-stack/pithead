import inspect
import json
import os
from collections import Counter
from pathlib import Path

import pytest

pytest_plugins = ["dashboard_wizard_terminal_plugin"]

ROOT = Path(__file__).resolve().parents[2]
CALLS = Counter()
ERRORS = Counter()


def _fatal(*args, **kwargs):
    del args, kwargs
    raise AssertionError("reference wizard submission used in Go mode")


async def _fatal_async(*args, **kwargs):
    del args, kwargs
    raise AssertionError("reference wizard submission used in Go mode")


def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_channel, go_wizard_submission
    from mining_dashboard.wizard import server

    os.environ.setdefault("PITHEAD_DASHBOARD_GO_BINARY", str(ROOT / "go/bin/dashboard"))
    go_wizard_submission.install(server)
    for original in go_wizard_submission.REFERENCE_FUNCTIONS.values():
        original.__code__ = (
            _fatal_async if inspect.iscoroutinefunction(original) else _fatal
        ).__code__
    call = go_channel.call

    def counted(helper, payload):
        label = f"{payload.get('operation', '')}:{payload.get('phase', '')}"
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "wizard-submission":
                ERRORS[f"{label}:{type(error).__name__}"] += 1
            raise
        if helper == "wizard-submission":
            CALLS[label] += 1
        return value

    go_channel.call = counted


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native wizard submission calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native wizard submission errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
