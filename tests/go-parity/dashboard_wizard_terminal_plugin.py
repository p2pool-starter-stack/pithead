import json
import os
from collections import Counter
from pathlib import Path

import pytest

pytest_plugins = ["dashboard_wizard_config_plugin"]

ROOT = Path(__file__).resolve().parents[2]
CALLS = Counter()
ERRORS = Counter()


def _fatal(*args, **kwargs):
    del args, kwargs
    raise AssertionError("reference wizard terminal used in Go mode")


def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_channel, go_wizard_terminal
    from mining_dashboard.wizard import server

    os.environ.setdefault("PITHEAD_DASHBOARD_GO_BINARY", str(ROOT / "go/bin/dashboard"))
    go_wizard_terminal.install(server)
    for original in go_wizard_terminal.REFERENCE_FUNCTIONS.values():
        original.__code__ = _fatal.__code__
    call = go_channel.call

    def counted(helper, payload):
        label = f"{helper}:{payload.get('operation', '')}"
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "wizard-terminal":
                ERRORS[f"{label}:{type(error).__name__}"] += 1
            raise
        if helper == "wizard-terminal":
            CALLS[label] += 1
        return value

    go_channel.call = counted


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native wizard terminal calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native wizard terminal errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
