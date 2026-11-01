import json
import os
import subprocess
import time
from contextlib import contextmanager
from dataclasses import asdict, is_dataclass
from pathlib import Path

import pytest
from dashboard_average_session import AverageSession

# ruff: noqa: S603

pytest_plugins = ["dashboard_metrics_plugin"]

REPO_ROOT = Path(__file__).resolve().parents[2]
BINARY = REPO_ROOT / "go" / "bin" / "dashboard"

SERIES_OPERATIONS = (
    "build_share_stats",
    "_downsample_share_stats",
    "_filter_share_stats",
    "_window_reject_pct",
    "_downsample_gauge_rows",
    "build_blocks",
    "build_payouts",
    "_gauge_series",
    "build_disk_growth",
    "build_xvb_history",
    "_mode_palette",
    "build_hashrate",
    "build_cadence",
)
INFRA_OPERATIONS = (
    "build_system",
    "build_proxy_summary",
    "build_tari",
    "build_sync",
    "build_monero",
)
OPERATIONS = SERIES_OPERATIONS + INFRA_OPERATIONS
ORIGINALS = {}
AVERAGES = None


def _json_value(value):
    if is_dataclass(value) and not isinstance(value, type):
        return _json_value(asdict(value))
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    if hasattr(value, "__dict__"):
        return _json_value(vars(value))
    return value


def _run_helper(helper, operation, args):
    env = os.environ.copy()
    env["PITHEAD_DASHBOARD_HELPER"] = helper
    payload = {
        "operation": operation,
        "args": _json_value(args),
        "now": time.time(),
        "zone": os.environ.get("TZ", ""),
    }
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
        raise RuntimeError(detail[-1] if detail else f"Go {helper} helper failed")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Go {helper} helper returned invalid JSON") from exc


def native_build_share_stats(share_stats, range_arg, window=None):
    return _run_helper("series", "build_share_stats", [share_stats, range_arg, window])


def native__downsample_share_stats(rows, target=700):
    return _run_helper("series", "_downsample_share_stats", [rows, target])


def native__filter_share_stats(rows, range_arg, window=None):
    return _run_helper("series", "_filter_share_stats", [rows, range_arg, window])


def native__window_reject_pct(rows, seconds):
    return _run_helper("series", "_window_reject_pct", [rows, seconds])


def native__downsample_gauge_rows(rows, value_cols, target=700):
    return _run_helper("series", "_downsample_gauge_rows", [rows, value_cols, target])


def native_build_blocks(blocks, range_arg, window=None):
    return _run_helper("series", "build_blocks", [blocks, range_arg, window])


def native_build_payouts(state_mgr, range_arg, window=None):
    from mining_dashboard.config import config

    rows = {"monero": [], "tari": []}
    if state_mgr is not None:
        if config.PAYOUT_CONFIRM_ENABLED:
            rows["monero"] = state_mgr.get_payouts("monero")
        if config.TARI_PAYOUT_CONFIRM_ENABLED:
            rows["tari"] = state_mgr.get_payouts("tari")
    return _run_helper("series", "build_payouts", [rows, range_arg, window])


def native__gauge_series(rows, range_arg, window, value_cols):
    return _run_helper("series", "_gauge_series", [rows, range_arg, window, value_cols])


def native_build_disk_growth(rows, range_arg, window=None):
    return _run_helper("series", "build_disk_growth", [rows, range_arg, window])


def native_build_xvb_history(rows, range_arg, window=None):
    return _run_helper("series", "build_xvb_history", [rows, range_arg, window])


def native__mode_palette(current_mode):
    return tuple(_run_helper("series", "_mode_palette", [current_mode]))


def native_build_hashrate(metrics, mode_tok, p2p_tok, xvb_tok):
    return _run_helper("series", "build_hashrate", [metrics, mode_tok, p2p_tok, xvb_tok])


def native_build_cadence(metrics):
    return _run_helper("series", "build_cadence", [metrics])


def native_build_system(data):
    return _run_helper("infra", "build_system", [data])


def native_build_proxy_summary(data):
    return _run_helper("infra", "build_proxy_summary", [data])


def native_build_tari(data):
    return _run_helper("infra", "build_tari", [data])


def native_build_sync(metrics, monero_db_size):
    return _run_helper("infra", "build_sync", [metrics, monero_db_size])


def native_build_monero(data, metrics):
    return _run_helper("infra", "build_monero", [data, metrics])


NATIVES = {
    name.removeprefix("native_"): value
    for name, value in tuple(globals().items())
    if name.startswith("native_") and name.removeprefix("native_") in OPERATIONS
}


def _modules():
    from mining_dashboard.web.views import (
        infra_views,
        monero_view,
        series_views,
        views,
        worker_detail,
    )

    return series_views, infra_views, monero_view, views, worker_detail


def _owner(name, series_views, infra_views, monero_view):
    if name in SERIES_OPERATIONS:
        return series_views
    if name == "build_monero":
        return monero_view
    return infra_views


def _set_operations(values):
    series_views, infra_views, monero_view, views, worker_detail = _modules()
    for name, value in values.items():
        setattr(_owner(name, series_views, infra_views, monero_view), name, value)
        if hasattr(views, name):
            setattr(views, name, value)
        if hasattr(worker_detail, name):
            setattr(worker_detail, name, value)


@contextmanager
def python_operations():
    _set_operations(ORIGINALS)
    try:
        yield
    finally:
        _set_operations(NATIVES)


def python_call(operation, *args, **kwargs):
    with python_operations():
        return ORIGINALS[operation](*args, **kwargs)


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    series_views, infra_views, monero_view, _views, _worker_detail = _modules()
    for name in OPERATIONS:
        ORIGINALS[name] = getattr(_owner(name, series_views, infra_views, monero_view), name)
    _set_operations(NATIVES)


@pytest.hookimpl(trylast=True)
def pytest_sessionstart(session):
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    import dashboard_metrics_plugin

    global AVERAGES
    AVERAGES = AverageSession(BINARY, REPO_ROOT)
    dashboard_metrics_plugin._run_average = AVERAGES.run_average
    if session.config.pluginmanager.get_plugin("_cov") is None:
        return
    if getattr(session.config.option, "no_cov", False):
        return
    import importlib

    importlib.reload(_modules()[3])
    _set_operations(NATIVES)


def pytest_unconfigure(config):
    del config
    if AVERAGES is not None:
        AVERAGES.close()
