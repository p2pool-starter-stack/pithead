import json
import os
from collections import Counter
from pathlib import Path

import pytest

pytest_plugins = ["dashboard_control_http_plugin"]

ROOT = Path(__file__).resolve().parents[2]
CALLS = Counter()
ERRORS = Counter()


class _CountablePayload(dict):
    def __missing__(self, key):
        if key == "operation":
            return self.get("phase", "")
        raise KeyError(key)


def _fatal(*args, **kwargs):
    del args, kwargs
    raise AssertionError("reference wizard preparation used in Go mode")


def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_channel, go_wizard_preparation
    from mining_dashboard.wizard import server

    os.environ.setdefault("PITHEAD_DASHBOARD_GO_BINARY", str(ROOT / "go/bin/dashboard"))
    go_wizard_preparation.install(server)
    go_wizard_preparation.REFERENCE_FUNCTIONS["_config"].__code__ = _fatal.__code__
    call = go_channel.call

    def counted(helper, payload):
        phase = payload.get("phase", "")
        if helper == "wizard-preparation":
            payload = _CountablePayload(payload)
        try:
            value = call(helper, payload)
        except Exception as error:
            if helper == "wizard-preparation":
                ERRORS[f"{phase}:{type(error).__name__}"] += 1
                if trace := os.environ.get("PITHEAD_WIZARD_PREPARATION_TRACE"):
                    with Path(trace).open("a") as stream:
                        stream.write(f"{phase}:error\n")
            raise
        if helper == "wizard-preparation":
            CALLS[phase] += 1
            if trace := os.environ.get("PITHEAD_WIZARD_PREPARATION_TRACE"):
                with Path(trace).open("a") as stream:
                    stream.write(f"{phase}\n")
        return value

    go_channel.call = counted


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native wizard preparation calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "native wizard preparation errors " + json.dumps(dict(ERRORS), sort_keys=True)
        )
