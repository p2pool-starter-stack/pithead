import math
import os
import time
from contextlib import contextmanager
from dataclasses import asdict, is_dataclass
from pathlib import Path

import pytest
from dashboard_fleet_session import JSONSession

pytest_plugins = ["dashboard_views_plugin"]

REPO_ROOT = Path(__file__).resolve().parents[2]
BINARY = REPO_ROOT / "go" / "bin" / "dashboard"
FLEET_OPERATIONS = (
    "build_workers",
    "rigforge_display",
    "rigforge_update_for",
    "_reject_flag",
    "_ip_to_sort_int",
    "_num",
    "_fmt",
    "build_energy",
)
RESOURCE_OPERATIONS = ("build_host_resources", "capacity_outlook")
OPERATIONS = FLEET_OPERATIONS + RESOURCE_OPERATIONS
FLEET_ORIGINALS = {}
FLEET = None
RESOURCES = None


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


def _resource_json(value):
    value = _json_value(value)
    if isinstance(value, float) and not math.isfinite(value):
        label = "nan" if math.isnan(value) else "inf" if value > 0 else "-inf"
        return {"__pithead_nonfinite__": label}
    if isinstance(value, dict):
        return {key: _resource_json(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_resource_json(item) for item in value]
    return value


def _fleet(operation, args):
    if FLEET is None:
        raise RuntimeError("Go fleet helper is unavailable")
    return FLEET.run({"operation": operation, "args": _json_value(args), "now": time.time()})


def _resources(operation, args, now):
    if RESOURCES is None:
        raise RuntimeError("Go resources helper is unavailable")
    from mining_dashboard.service import host_resources

    return RESOURCES.run(
        _resource_json(
            {
                "operation": operation,
                "args": args,
                "now": now,
                "max_age": host_resources._MAX_AGE,
            }
        )
    )


def native_build_workers(workers, rigforge_release=None):
    return _fleet("build_workers", [workers, rigforge_release])


def native_rigforge_display(rf, proxy_online=False):
    return _fleet("rigforge_display", [rf, proxy_online])


def native_rigforge_update_for(worker, release):
    return _fleet("rigforge_update_for", [worker, release])


def native__reject_flag(accepted, rejected):
    return _fleet("_reject_flag", [accepted, rejected])


def native__ip_to_sort_int(ip):
    return _fleet("_ip_to_sort_int", [ip])


def native__num(value):
    return _fleet("_num", [value])


def native__fmt(value):
    return _fleet("_fmt", [value])


def native_build_energy(workers, prices=None):
    from mining_dashboard.config import config

    return _fleet(
        "build_energy",
        [workers, prices, config.DASHBOARD_ENERGY, config.current_worker_endpoints()],
    )


def native_build_host_resources(samples, disk_rows, now=None):
    from mining_dashboard.service import host_resources

    request_now = host_resources.time.time()
    return _resources("build_host_resources", [samples, disk_rows, now], request_now)


def native_capacity_outlook(rows, filesystem, now):
    return _resources("capacity_outlook", [rows, filesystem, now], now)


NATIVES = {
    name.removeprefix("native_"): value
    for name, value in tuple(globals().items())
    if name.startswith("native_") and name.removeprefix("native_") in OPERATIONS
}


def _modules():
    from mining_dashboard.service import host_resources
    from mining_dashboard.web.views import infra_views, rigforge_views, views, worker_detail

    return infra_views, rigforge_views, host_resources, views, worker_detail


def _originals():
    infra, rigforge, resources, _views, _worker = _modules()
    return {
        "build_workers": infra.build_workers,
        "rigforge_display": rigforge.rigforge_display,
        "rigforge_update_for": infra.rigforge_update_for,
        "_reject_flag": infra._reject_flag,
        "_ip_to_sort_int": infra._ip_to_sort_int,
        "_num": rigforge._num,
        "_fmt": rigforge._fmt,
        "build_energy": infra.build_energy,
        "build_host_resources": resources.build_host_resources,
        "capacity_outlook": resources.capacity_outlook,
    }


def _set_operations(values):
    infra, rigforge, resources, views, worker = _modules()
    infra.build_workers = values["build_workers"]
    infra.rigforge_update_for = values["rigforge_update_for"]
    infra._reject_flag = values["_reject_flag"]
    infra._ip_to_sort_int = values["_ip_to_sort_int"]
    infra._num = values["_num"]
    infra.build_energy = values["build_energy"]
    rigforge.rigforge_display = values["rigforge_display"]
    rigforge._num = values["_num"]
    rigforge._fmt = values["_fmt"]
    resources.build_host_resources = values["build_host_resources"]
    resources.capacity_outlook = values["capacity_outlook"]
    for module in (infra, views, worker):
        if hasattr(module, "_rigforge_display"):
            module._rigforge_display = values["rigforge_display"]
    for module in (views, worker):
        if hasattr(module, "rigforge_update_for"):
            module.rigforge_update_for = values["rigforge_update_for"]
    views.build_workers = values["build_workers"]
    views.build_energy = values["build_energy"]
    views.build_host_resources = values["build_host_resources"]


@contextmanager
def python_operations():
    import dashboard_views_plugin

    with dashboard_views_plugin.python_operations():
        _set_operations(FLEET_ORIGINALS)
        try:
            yield
        finally:
            _set_operations(NATIVES)


def python_call(operation, *args, **kwargs):
    with python_operations():
        return FLEET_ORIGINALS[operation](*args, **kwargs)


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    FLEET_ORIGINALS.update(_originals())
    _set_operations(NATIVES)


@pytest.hookimpl(hookwrapper=True)
def pytest_sessionstart(session):
    yield
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard.service import host_resources

    if session.config.pluginmanager.get_plugin("_cov") is not None and not getattr(
        session.config.option, "no_cov", False
    ):
        import importlib

        importlib.reload(host_resources)

    global FLEET, RESOURCES
    FLEET = JSONSession(
        BINARY,
        REPO_ROOT,
        "fleet-stream",
        {"operation": "_ip_to_sort_int", "args": ["0.0.0.0"], "now": 0},
    )
    RESOURCES = JSONSession(
        BINARY,
        REPO_ROOT,
        "resources-stream",
        {
            "operation": "build_host_resources",
            "args": [{}, [], 0],
            "now": 0,
            "max_age": host_resources._MAX_AGE,
        },
    )
    _set_operations(NATIVES)


def pytest_unconfigure(config):
    del config
    for session in (FLEET, RESOURCES):
        if session is not None:
            session.close()
