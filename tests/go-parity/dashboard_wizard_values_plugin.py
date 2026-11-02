import json
import os
from collections import Counter
from pathlib import Path

import pytest

pytest_plugins = ["dashboard_wizard_typed_plugin"]

ROOT = Path(__file__).resolve().parents[2]
_UNLINK = os.unlink
CALLS = Counter()
HOOKED = Counter()
ERRORS = Counter()


def _fatal(*args, **kwargs):
    del args, kwargs
    raise AssertionError("reference wizard values used in Go mode")


def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_channel, go_wizard_values
    from mining_dashboard.wizard import server

    os.environ.setdefault("PITHEAD_DASHBOARD_GO_BINARY", str(ROOT / "go/bin/dashboard"))
    go_wizard_values.install(server)
    for original in go_wizard_values.REFERENCE_FUNCTIONS.values():
        original.__code__ = _fatal.__code__
    call = go_channel.call

    def counted(helper, payload):
        operation = payload.get("operation", "")
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "wizard-values":
                ERRORS[f"{operation}:{type(error).__name__}"] += 1
            raise
        if helper == "wizard-values":
            CALLS[operation] += 1
        return value

    go_channel.call = counted
    native_remove = go_wizard_values._remove

    def remove(spool, names):
        if os.unlink is _UNLINK:
            return native_remove(spool, names)
        from dashboard_wizard_values_io import run

        try:
            value = run(
                {
                    "operation": "remove-spool",
                    "spool": spool,
                    "names": list(names),
                    "io_hooks": {"unlink": True},
                }
            )
        except Exception as error:
            ERRORS[f"remove-spool:{type(error).__name__}"] += 1
            raise
        HOOKED["remove-spool"] += 1
        return value

    go_wizard_values._remove = remove


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        from dashboard_wizard_values_io import CALLBACKS

        terminalreporter.write_sep(
            "=", "native wizard values calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native wizard values hooked " + json.dumps(dict(HOOKED), sort_keys=True)
        )
        terminalreporter.write_line(
            "native wizard values errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "wizard values I/O callbacks " + json.dumps(dict(CALLBACKS), sort_keys=True)
        )
