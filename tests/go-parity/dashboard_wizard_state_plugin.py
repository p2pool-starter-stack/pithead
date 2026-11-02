import inspect
import json
import os
from collections import Counter
from pathlib import Path

import pytest

pytest_plugins = ["dashboard_wizard_preparation_plugin"]

ROOT = Path(__file__).resolve().parents[2]
CALLS = Counter()
ERRORS = Counter()


async def _fatal_async(*args, **kwargs):
    del args, kwargs
    raise AssertionError("reference wizard state used in Go mode")


def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_channel, go_wizard_state
    from mining_dashboard.wizard import server

    os.environ.setdefault("PITHEAD_DASHBOARD_GO_BINARY", str(ROOT / "go/bin/dashboard"))
    go_wizard_state.install(server)
    original = go_wizard_state.REFERENCE_FUNCTIONS["wizard_state"]
    if not inspect.iscoroutinefunction(original):
        raise RuntimeError("captured wizard state is not async")
    original.__code__ = _fatal_async.__code__
    call = go_channel.call

    def counted(helper, payload):
        phase = payload.get("phase", "")
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "wizard-state":
                ERRORS[f"{phase}:{type(error).__name__}"] += 1
                if trace := os.environ.get("PITHEAD_WIZARD_STATE_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{phase}:error\n")
            raise
        if helper == "wizard-state":
            CALLS[phase] += 1
            if trace := os.environ.get("PITHEAD_WIZARD_STATE_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{phase}\n")
        return value

    go_channel.call = counted


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native wizard state calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native wizard state errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
