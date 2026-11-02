import sys

from mining_dashboard.go_control_http import _check, _NativeFailure, _plan, _reply

REFERENCE_FUNCTIONS = {}


def _value(operation, **values):
    plan = _check(_plan(operation, **values))
    if "value" not in plan:
        raise _NativeFailure("missing native worker HTTP value")
    return plan["value"]


def _done(result):
    plan = _plan("worker-done", value=result.get("status"))
    if type(plan.get("done")) is not bool:
        raise _NativeFailure("invalid native worker HTTP predicate")
    return plan["done"]


def _record_worker_result(state_mgr, worker, changes, res, change_type="apply"):
    res.get("status", "unknown")
    plan = _plan("worker-record", value=res)
    if plan.get("next") == "ready":
        return
    if plan.get("next") != "record" or not isinstance(plan.get("value"), dict):
        raise _NativeFailure("invalid native worker history plan")
    value = plan["value"]
    if any(name not in value for name in ("change_id", "status", "reason")):
        raise _NativeFailure("incomplete native worker history plan")
    state_mgr.add_worker_config_version(
        worker,
        value["change_id"],
        value["status"],
        changes,
        value["reason"],
        change_type=change_type,
    )


async def handle_worker_detail(request):
    from mining_dashboard.web import server

    name = request.query.get("name", "")
    _check(_plan("worker-detail-name", value=name))
    app = request.app
    data = app["latest_data"] or {}
    state_mgr = app["state_manager"]
    range_arg = request.query.get("range", "all")
    window = server.parse_window(request.query.get("from"), request.query.get("to"))
    try:
        result = server.build_worker_detail(name, data, state_mgr, range_arg, window)
        return _reply(_plan("complete", route="worker-detail", value=result))
    except _NativeFailure:
        raise
    except Exception:
        server.logger.exception("Error building worker detail")
        return _reply(_plan("error", error="worker-detail"))


async def handle_worker_apply(request):
    from mining_dashboard.web import server

    server._require_control_header(request)
    try:
        body = await request.json()
    except Exception:
        _reply(_plan("error", error="json"))
    worker = body.get("worker")
    changes = body.get("changes")
    _check(_plan("worker-name", value=worker))
    error = server.control_service.validate_worker_changes(changes)
    _check(_plan("validation", value=error))
    changes = _value("worker-strip", value=changes)
    actor = request.headers.get("X-Auth-User", "")
    state_mgr = request.app["state_manager"]
    try:
        rid = server.control_service.submit_worker_apply(worker, changes, actor)
        result = await server.control_service.wait_result(rid, done=_done)
    except _NativeFailure:
        raise
    except Exception:
        server.logger.exception("Error submitting worker-apply")
        return _reply(_plan("error", route="worker-apply", error="submit"))
    if result is not None:
        server._record_worker_result(state_mgr, worker, changes, result)
        server.worker_refresh.maybe_refresh_after_apply(
            request.app, state_mgr, worker, changes, result
        )
    return _reply(_plan("complete", route="worker-apply", id=rid, value=result))


async def _finalize_worker_upgrade(state_mgr, worker, version, rid, latest_data=None) -> None:
    from mining_dashboard.web import server

    try:
        result = await server.control_service.wait_result(
            rid, done=_done, timeout_s=server.config.CONTROL_WORKER_UPGRADE_WAIT_S
        )
    except _NativeFailure:
        raise
    except Exception:
        server.logger.exception("Error waiting for worker-upgrade result (id=%s)", rid)
        return
    if result is not None:
        server._record_worker_result(
            state_mgr, worker, {"version": version}, result, change_type="upgrade"
        )
        await server.worker_refresh.maybe_refresh_after_upgrade(
            latest_data, worker, version, result
        )


async def handle_worker_upgrade(request):
    from mining_dashboard.web import server

    server._require_control_header(request)
    try:
        body = await request.json()
    except Exception:
        _reply(_plan("error", error="json"))
    worker = body.get("worker")
    version = body.get("version")
    _check(_plan("worker-name", value=worker))
    _check(_plan("version", route="upgrade", version=version))
    rigforge = _value("worker-live", value=request.app["latest_data"] or {}, worker=worker)
    running = None if server.feed_stale(rigforge) else rigforge.get("version")
    plan = _plan(
        "worker-noop",
        value=running,
        worker=worker,
        version=version,
        max_digits=sys.get_int_max_str_digits(),
    )
    if plan.get("status"):
        return _reply(plan)
    _check(plan)
    try:
        rid = server.control_service.submit_worker_upgrade(
            worker, version, request.headers.get("X-Auth-User", "")
        )
    except _NativeFailure:
        raise
    except Exception:
        server.logger.exception("Error submitting worker-upgrade")
        return _reply(_plan("error", route="worker-upgrade", error="submit"))
    state_mgr = request.app["state_manager"]
    bg_tasks = request.app["_bg_tasks"]
    task = server.asyncio.create_task(
        server._finalize_worker_upgrade(state_mgr, worker, version, rid, request.app["latest_data"])
    )
    bg_tasks.add(task)
    task.add_done_callback(bg_tasks.discard)
    return _reply(_plan("complete", route="worker-upgrade", id=rid))


def install(server):
    for name in (
        "handle_worker_detail",
        "handle_worker_apply",
        "handle_worker_upgrade",
        "_record_worker_result",
        "_finalize_worker_upgrade",
    ):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(server, name))
        setattr(server, name, globals()[name])
