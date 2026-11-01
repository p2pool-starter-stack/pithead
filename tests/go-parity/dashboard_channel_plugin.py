import base64
import json
import os
import uuid
from collections import Counter
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
CALLS = Counter()
COMPATIBILITY = Counter()
_REPLACE = os.replace
_UUID4 = uuid.uuid4


def _fatal(*args, **kwargs):
    del args, kwargs
    raise AssertionError("reference channel implementation used in Go mode")


def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard import go_channel, go_control, go_wizard
    from mining_dashboard.service import control_service, request_spool
    from mining_dashboard.wizard import server as wizard

    os.environ.setdefault("PITHEAD_DASHBOARD_GO_BINARY", str(ROOT / "go/bin/dashboard"))
    control_names = (
        "submit",
        "submit_worker_apply",
        "submit_worker_upgrade",
        "validate_worker_changes",
        "result",
    )
    wizard_names = (
        "wizard_stage",
        "installer_mode",
        "status",
        "_spool_read",
        "_reference",
        "_last_attempt",
        "_rig_defaults",
        "_data_wiped",
        "_saved_role",
    )
    originals = [request_spool.write]
    originals += [getattr(control_service, name) for name in control_names]
    originals += [
        go_wizard.REFERENCE_FUNCTIONS.get(name, getattr(wizard, name)) for name in wizard_names
    ]
    go_control.install()
    go_wizard.install()
    for function in originals:
        function.__code__ = _fatal.__code__

    run = go_channel.call

    def counted(helper, payload):
        value = run(helper, payload)
        CALLS[f"{helper}:{payload['operation']}"] += 1
        return value

    go_channel.call = counted
    submit = go_control._submit

    def injected_uuid(**payload):
        if not payload.get("id") and uuid.uuid4 is not _UUID4:
            payload["id"] = str(uuid.uuid4())
            COMPATIBILITY["injected-uuid"] += 1
        return submit(**payload)

    go_control._submit = injected_uuid
    write = go_control.write

    def observed_write(request):
        if os.replace is _REPLACE:
            return write(request)
        rid = request["id"]
        directory = request_spool.config.CONTROL_REQUESTS_DIR
        temp = go_channel.call(
            "control",
            {
                "operation": "control-stage",
                "directory": directory,
                "id": str(rid),
                "data": base64.b64encode(json.dumps(request).encode()).decode(),
            },
        )
        COMPATIBILITY["injected-replace"] += 1
        try:
            os.replace(temp, os.path.join(directory, f"{rid}.json"))
        except BaseException:
            try:
                os.unlink(temp)
            except FileNotFoundError:
                pass
            raise
        return rid

    request_spool.write = observed_write


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    if os.environ.get("PITHEAD_IMPL") == "go":
        terminalreporter.write_sep(
            "=", "native channel calls " + json.dumps(dict(CALLS), sort_keys=True)
        )
        terminalreporter.write_line(
            "explicit mock interpositions " + json.dumps(dict(COMPATIBILITY), sort_keys=True)
        )
