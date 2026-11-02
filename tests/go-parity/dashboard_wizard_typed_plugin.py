import inspect
import json
import os
from collections import Counter
from pathlib import Path

import pytest

pytest_plugins = ["dashboard_wizard_submission_plugin"]

ROOT = Path(__file__).resolve().parents[2]
CALLS = Counter()
ERRORS = Counter()


class _CountablePayload(dict):
    def __missing__(self, key):
        if key == "operation":
            return self.get("phase", "")
        raise KeyError(key)


async def _fatal_async(*args, **kwargs):
    del args, kwargs
    raise AssertionError("reference typed wizard submission used in Go mode")


def _fatal(*args, **kwargs):
    del args, kwargs
    raise AssertionError("reference typed wizard submission used in Go mode")


def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_channel, go_wizard_typed
    from mining_dashboard.wizard import server

    os.environ.setdefault("PITHEAD_DASHBOARD_GO_BINARY", str(ROOT / "go/bin/dashboard"))
    go_wizard_typed.install(server)
    for original in go_wizard_typed.REFERENCE_FUNCTIONS.values():
        fatal = _fatal_async if inspect.iscoroutinefunction(original) else _fatal
        original.__code__ = fatal.__code__
    call = go_channel.call

    def counted(helper, payload):
        phase = payload.get("phase", "")
        if helper == "wizard-typed":
            payload = _CountablePayload(payload)
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "wizard-typed":
                ERRORS[f"{phase}:{type(error).__name__}"] += 1
            raise
        if helper == "wizard-typed":
            CALLS[phase] += 1
        return value

    go_channel.call = counted


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native typed wizard calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native typed wizard errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
