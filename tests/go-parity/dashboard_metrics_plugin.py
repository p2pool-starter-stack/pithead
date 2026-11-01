import json
import os
import subprocess
from pathlib import Path

import pytest

# ruff: noqa: S603

pytest_plugins = ["dashboard_state_plugin"]

REPO_ROOT = Path(__file__).resolve().parents[2]
BINARY = REPO_ROOT / "go" / "bin" / "dashboard"

PYTHON_BUILD_METRICS = None
PYTHON_AVG_P2POOL = None
PYTHON_AVG_XVB = None


def _tiers(value):
    return [{"name": name, "threshold": threshold} for name, threshold in value.items()]


def _run_helper(payload):
    env = os.environ.copy()
    env["PITHEAD_DASHBOARD_HELPER"] = "domain"
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
        detail = result.stderr.strip().splitlines()
        raise RuntimeError(detail[-1] if detail else "Go metrics helper failed")
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Go metrics helper returned invalid JSON") from exc
    if isinstance(value, dict) and "metrics" in value and set(value) <= {"metrics"}:
        value = value["metrics"]
    if not isinstance(value, dict):
        raise RuntimeError("Go metrics helper returned a non-object")
    return value


def _run_average(history, window, now, xvb):
    env = os.environ.copy()
    env["PITHEAD_DASHBOARD_HELPER"] = "average"
    payload = {"history": history, "window": window, "now": now, "xvb": xvb}
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
        detail = result.stderr.strip().splitlines()
        raise RuntimeError(detail[-1] if detail else "Go average helper failed")
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Go average helper returned invalid JSON") from exc
    if isinstance(value, dict) and set(value) <= {"average"}:
        value = value.get("average")
    if not isinstance(value, (int, float)):
        raise RuntimeError("Go average helper returned a non-number")
    return value


def native_avg_p2pool(history, window_seconds):
    import mining_dashboard.service.metrics as metrics

    return _run_average(history, window_seconds, metrics.time.time(), False)


def native_avg_xvb(history, window_seconds):
    import mining_dashboard.service.metrics as metrics

    return _run_average(history, window_seconds, metrics.time.time(), True)


def native_build_metrics(latest_data, state_mgr, history=None):
    import mining_dashboard.service.metrics as metrics
    from mining_dashboard.config import config
    from mining_dashboard.helper import utils

    data = latest_data or {}
    if history is None:
        history = state_mgr.get_history()
    xvb_stats = state_mgr.get_xvb_stats() or {}
    tiers = state_mgr.get_tiers()
    payload = {
        "latest_data": data,
        "history": history,
        "xvb_stats": xvb_stats,
        "tiers": _tiers(tiers),
        "config": {
            "enable_xvb": metrics.ENABLE_XVB,
            "donation_level": metrics.XVB_DONATION_LEVEL,
            "max_donation_fraction": metrics.XVB_MAX_DONATION_FRACTION,
            "xvb_stats_stale_after_s": utils.XVB_STATS_STALE_AFTER_S,
            "monero_node_host": metrics.MONERO_NODE_HOST,
            "local_monero_host": metrics.LOCAL_MONERO_HOST,
            "monero_prune": metrics.MONERO_PRUNE,
            "tari_mode": config.TARI_MODE,
            "monero_local": metrics.monero_is_local(),
            "tari_local": metrics.tari_is_local(),
        },
        "now": metrics.time.time(),
    }
    value = _run_helper(payload)
    nested = {}
    for name in ("monero", "tari"):
        raw = value.get(name)
        if not isinstance(raw, dict):
            raise RuntimeError(f"Go metrics helper omitted {name}")
        nested[name] = metrics.SyncMetric(**raw)
    value["monero"] = nested["monero"]
    value["tari"] = nested["tari"]
    return metrics.Metrics(**value)


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    import mining_dashboard.service.metrics as metrics
    from mining_dashboard.web import server
    from mining_dashboard.web.views import views

    global PYTHON_BUILD_METRICS
    global PYTHON_AVG_P2POOL, PYTHON_AVG_XVB
    PYTHON_BUILD_METRICS = metrics.build_metrics
    PYTHON_AVG_P2POOL = metrics._avg_p2pool_over_window
    PYTHON_AVG_XVB = metrics._avg_xvb_over_window
    metrics.build_metrics = native_build_metrics
    metrics._avg_p2pool_over_window = native_avg_p2pool
    metrics._avg_xvb_over_window = native_avg_xvb
    server.build_metrics = native_build_metrics
    views.build_metrics = native_build_metrics
