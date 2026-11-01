import json
import os
from collections import Counter
from pathlib import Path

import pytest

pytest_plugins = ["dashboard_channel_plugin"]

ROOT = Path(__file__).resolve().parents[2]
_REPLACE = os.replace
_UNLINK = os.unlink
CALLS = Counter()
HOOKED = Counter()
ERRORS = Counter()


def _fatal(*args, **kwargs):
    del args, kwargs
    raise AssertionError("reference wizard transaction used in Go mode")


def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_wizard_transaction
    from mining_dashboard.wizard import server

    os.environ.setdefault("PITHEAD_DASHBOARD_GO_BINARY", str(ROOT / "go/bin/dashboard"))
    go_wizard_transaction.install(server)
    for original in go_wizard_transaction.REFERENCE_FUNCTIONS.values():
        original.__code__ = _fatal.__code__
    native = go_wizard_transaction._run

    def dispatch(operation, data=None, **values):
        hooks = {"replace": os.replace is not _REPLACE, "unlink": os.unlink is not _UNLINK}
        try:
            if any(hooks.values()):
                from dashboard_wizard_io import run

                payload = go_wizard_transaction._payload(operation, io_hooks=hooks, **values)
                result = run(payload, data)
                HOOKED[operation] += 1
            else:
                result = native(operation, data=data, **values)
                CALLS[operation] += 1
            return result
        except Exception as error:
            ERRORS[f"{operation}:{type(error).__name__}"] += 1
            raise

    go_wizard_transaction._run = dispatch


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        from dashboard_wizard_io import CALLBACKS

        terminalreporter.write_sep(
            "=", "native wizard transaction calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "explicit wizard I/O interpositions " + json.dumps(dict(HOOKED), sort_keys=True)
        )
        terminalreporter.write_line(
            "native wizard errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
        terminalreporter.write_line(
            "wizard I/O callbacks " + json.dumps(dict(CALLBACKS), sort_keys=True)
        )
