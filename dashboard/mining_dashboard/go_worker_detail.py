import copy
import os
import time

from mining_dashboard import go_channel

REFERENCE_FUNCTIONS = {}


def _run(operation, args, *, now=None):
    try:
        return go_channel.call(
            "fleet",
            {
                "operation": operation,
                "args": args,
                "now": time.time() if now is None else now,
                "zone": os.environ.get("TZ", ""),
                "envelope": True,
            },
        )
    except RuntimeError as error:
        from mining_dashboard.go_control_http import _NativeFailure

        raise _NativeFailure("native worker detail unavailable") from error


def config_origin(meta, change_id_known, change_status=None, history_unread=False):
    return _run("config_origin", [meta, change_id_known, change_status, history_unread])


def config_drift(last_applied, rig_config, unsettled=False):
    return _run("config_drift", [last_applied, rig_config, unsettled])


def _has_unsettled_apply(history):
    return _run("_has_unsettled_apply", [history])


def build_worker_hashrate_history(state_mgr, worker, range_arg, window=None):
    return _run(
        "build_worker_hashrate_history",
        [
            state_mgr.get_worker_history(name=worker),
            state_mgr.get_worker_config_history(worker, limit=200) or [],
            range_arg,
            window,
        ],
    )


def capture(name, data):
    now = time.time()
    workers = data.get("workers", []) if data else []
    worker = next((row for row in workers if row.get("name") == name), None)
    return {
        "timestamp": data.get("timestamp") if data else None,
        "rigforge_release": copy.deepcopy((data or {}).get("rigforge_release")),
        "workers": [] if worker is None else [copy.deepcopy(worker)],
    }, now


def prepare(name, data, state_mgr, range_arg="all", window=None, *, now):
    from mining_dashboard.web.views import worker_detail

    worker = next((row for row in data["workers"] if row.get("name") == name), None)
    descriptor = next(
        (row for row in worker_detail.config.current_worker_endpoints() if row["name"] == name),
        None,
    )
    history = state_mgr.get_worker_config_history(name, limit=worker_detail._HISTORY_LIMIT)
    by_config = state_mgr.get_worker_hashrate_by_config(name)
    meta = (worker.get("rigforge") or {}).get("config_meta") if worker else None
    matched = state_mgr.get_worker_config_change(name, (meta or {}).get("last_change_id"))
    last_applied = state_mgr.get_last_applied_worker_config(name)
    revision_drift = state_mgr.get_worker_revision_drift(name, (meta or {}).get("revision"))
    samples = state_mgr.get_worker_history(name=name)
    markers = state_mgr.get_worker_config_history(name, limit=200) or []
    return copy.deepcopy(
        {
            "name": name,
            "now": now,
            "data": data,
            "descriptor": descriptor,
            "history": history,
            "hashrate_by_config": by_config,
            "matched": matched,
            "last_applied": last_applied,
            "revision_drift": revision_drift,
            "worker_history": samples,
            "marker_history": markers,
            "range_arg": range_arg,
            "window": window,
            "control_enabled": worker_detail.config.DASHBOARD_CONTROL_ENABLED,
            "writable_keys": sorted(worker_detail.WORKER_WRITABLE_KEYS),
        }
    )


def build_prepared(prepared, *, now=None):
    result = _run("build_worker_detail", [prepared], now=prepared["now"] if now is None else now)
    if not isinstance(result, dict) or set(result) != {
        "name",
        "snapshot_at",
        "found",
        "editable",
        "control_enabled",
        "ip",
        "status",
        "hashrate",
        "rigforge",
        "rigforge_update",
        "writable_keys",
        "rig_config",
        "rig_config_meta",
        "config_origin",
        "last_applied",
        "config_drift",
        "config_revision_drift",
        "history",
        "hashrate_by_config",
        "hashrate_history",
    }:
        from mining_dashboard.go_control_http import _NativeFailure

        raise _NativeFailure("invalid native worker detail result")
    if (
        not isinstance(result["name"], str)
        or any(type(result[key]) is not bool for key in ("found", "editable", "control_enabled"))
        or any(
            result[key] is not None and not isinstance(result[key], str)
            for key in ("ip", "status", "hashrate", "config_origin")
        )
        or any(
            result[key] is not None and not isinstance(result[key], dict)
            for key in (
                "rigforge",
                "rigforge_update",
                "rig_config",
                "rig_config_meta",
                "last_applied",
                "config_revision_drift",
            )
        )
        or any(
            not isinstance(result[key], list)
            for key in ("writable_keys", "history", "hashrate_by_config")
        )
        or any(not isinstance(key, str) for key in result["writable_keys"])
        or (result["config_drift"] is not None and not isinstance(result["config_drift"], list))
        or not isinstance(result["hashrate_history"], dict)
        or set(result["hashrate_history"]) != {"hashrate", "markers"}
        or any(not isinstance(rows, list) for rows in result["hashrate_history"].values())
    ):
        from mining_dashboard.go_control_http import _NativeFailure

        raise _NativeFailure("invalid native worker detail types")
    return result


def build_captured(name, data, state_mgr, range_arg, window, *, now):
    return build_prepared(prepare(name, data, state_mgr, range_arg, window, now=now))


def build_worker_detail(name, data, state_mgr, range_arg="all", window=None):
    data, now = capture(name, data)
    return build_captured(name, data, state_mgr, range_arg, window, now=now)


def install():
    from mining_dashboard.client import rig_config_meta
    from mining_dashboard.web import server
    from mining_dashboard.web.views import worker_detail

    for name in (
        "build_worker_detail",
        "build_worker_hashrate_history",
        "config_drift",
        "_has_unsettled_apply",
        "config_origin",
    ):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(worker_detail, name))
        setattr(worker_detail, name, globals()[name])
    rig_config_meta.config_origin = config_origin
    server.build_worker_detail = build_worker_detail
