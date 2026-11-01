import json
import os
import subprocess
from pathlib import Path

import pytest

from mining_dashboard.web.views import charts, views

# ruff: noqa: S603

pytest_plugins = ["dashboard_http_plugin"]

REPO_ROOT = Path(__file__).resolve().parents[2]
BINARY = REPO_ROOT / "go" / "bin" / "dashboard"
PYTHON_BUILD_CHART = charts.build_chart


def native_build_chart(
    history,
    shares,
    range_arg,
    window=None,
    avg_window=charts.DEFAULT_HASHRATE_WINDOW,
    events=None,
    raffle_wins=None,
    payouts=None,
):
    payload = {
        "history": history,
        "shares": shares,
        "range": range_arg,
        "window": window,
        "avg_window": avg_window,
        "events": list(events or []),
        "raffle_wins": list(raffle_wins or []),
        "payouts": list(payouts or []),
        "now": charts.time.time(),
        "update_interval": charts.UPDATE_INTERVAL,
    }
    env = os.environ.copy()
    env["PITHEAD_DASHBOARD_HELPER"] = "chart"
    result = subprocess.run(
        [BINARY],
        input=json.dumps(payload, allow_nan=False, separators=(",", ":")),
        text=True,
        capture_output=True,
        cwd=REPO_ROOT,
        env=env,
        timeout=10,
        check=False,
    )
    if result.returncode != 0:
        message = result.stderr.strip().splitlines()
        raise RuntimeError(message[-1] if message else "Go chart helper failed")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Go chart helper returned invalid JSON") from exc


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    import dashboard_http_plugin

    from mining_dashboard import go_bridge

    original = dashboard_http_plugin._ORIGINAL_CREATE_APP
    if original is None:
        raise RuntimeError("dashboard HTTP parity plugin was not configured")

    def create_app(state_manager, latest_data_ref):
        app = original(state_manager, latest_data_ref)
        go_bridge.install(app)
        return app

    dashboard_http_plugin._ORIGINAL_CREATE_APP = create_app
    charts.build_chart = native_build_chart
    views.build_chart = native_build_chart
