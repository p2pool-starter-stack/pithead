from aiohttp import web

from mining_dashboard import go_channel
from mining_dashboard.go_wizard_config import _tree, _value

REFERENCE_FUNCTIONS = {}


class _NativeFailure(RuntimeError):
    pass


def _plan(operation, *, route="", error="", **values):
    identities = {}
    payload = {key: _tree(value, identities) for key, value in values.items()}
    try:
        result = go_channel.call(
            "control-http", {"operation": operation, "route": route, "error": error, **payload}
        )
    except RuntimeError as failure:
        raise _NativeFailure(str(failure)) from failure
    if not isinstance(result, dict):
        raise _NativeFailure("invalid native control HTTP response")
    originals = {number: value for number, value in identities.values()}
    try:
        for key in ("value", "body", "text"):
            if key in result:
                result[key] = _value(result[key], originals)
    except (KeyError, TypeError, ValueError, RuntimeError) as failure:
        raise _NativeFailure("invalid native control HTTP value") from failure
    _validate_plan(operation, result)
    return result


def _validate_plan(operation, plan):
    if "status" in plan:
        if plan.get("next") not in (None, ""):
            raise _NativeFailure("native control HTTP response cannot continue")
        if type(plan["status"]) is not int or plan["status"] not in (200, 202, 400, 403, 500):
            raise _NativeFailure("invalid native control HTTP status")
        if ("text" in plan) == ("body" in plan):
            raise _NativeFailure("invalid native control HTTP response body")
        if "text" in plan and plan["status"] not in (400, 403):
            raise _NativeFailure("invalid native control HTTP text status")
        if "body" in plan and plan["status"] not in (200, 202, 500):
            raise _NativeFailure("invalid native control HTTP JSON status")
    elif operation in ("complete", "error"):
        raise _NativeFailure("missing native control HTTP response")
    elif operation == "approval":
        if (
            "value" not in plan
            or (plan["value"] is None and plan.get("next") not in (None, ""))
            or (
                plan["value"] is not None
                and (
                    plan.get("next") != "approval"
                    or not isinstance(plan["value"], dict)
                    or not isinstance(plan["value"].get("payout_suffixes"), dict)
                )
            )
        ):
            raise _NativeFailure("invalid native control HTTP approval")
    elif operation in ("request", "os-action"):
        expected = "submit" if operation == "request" else "ready"
        if plan.get("next") != expected or not isinstance(plan.get("action"), str):
            raise _NativeFailure("invalid native control HTTP action")
    elif operation in ("done", "worker-done"):
        if type(plan.get("done")) is not bool:
            raise _NativeFailure("invalid native control HTTP result predicate")
    elif not isinstance(plan.get("next"), str):
        raise _NativeFailure("invalid native control HTTP phase")


def _reply(plan):
    status = plan.get("status", 200)
    if "text" in plan:
        exception = {400: web.HTTPBadRequest, 403: web.HTTPForbidden}[status]
        raise exception(text=plan["text"])
    return web.json_response(plan["body"], status=status)


def _check(plan, expected="ready"):
    if plan.get("status"):
        _reply(plan)
    if plan.get("next") != expected:
        raise _NativeFailure("invalid native control HTTP phase")
    return plan


def _require_control_header(request):
    from mining_dashboard.web import server

    _check(_plan("header", value=request.headers.get(server.CONTROL_HEADER)))


async def config_request(request):
    from mining_dashboard.config import documents

    try:
        body = await request.json(loads=documents.loads)
        plan = _plan("request-body", value=body)
        if plan.get("status"):
            _reply(plan)
        if plan.get("next") == "placeholders":
            documents.reject_placeholders(body["config"])
        elif plan.get("next") != "ready":
            raise _NativeFailure("invalid native control body phase")
    except documents.ConfigDocumentError as error:
        _reply(_plan("error", error="document", value=error.diagnostic()))
    except web.HTTPBadRequest:
        raise
    except _NativeFailure:
        raise
    except Exception:
        _reply(_plan("error", error="json"))
    return body


def approval_envelope(body):
    body.get("approve")
    plan = _plan("approval", value=body)
    approval = plan["value"]
    if plan.get("next") == "approval":
        approval["payout_suffixes"] = body.get("payout_suffixes", {})
    return approval


async def handle_config(request):
    from mining_dashboard.web import server

    try:
        return _reply(_plan("complete", route="config", value=server.control_service.read_config()))
    except server.documents.HostConfigError as error:
        return _reply(_plan("error", error="config-host", value=str(error)))
    except _NativeFailure:
        raise
    except Exception:
        server.logger.exception("Error reading host config")
        return _reply(_plan("error", error="config-read"))


async def handle_control_preview(request):
    from mining_dashboard.web import server

    server._require_control_header(request)
    body = await server.config_request(request)
    proposed = body.get("config")
    _check(_plan("proposed", value=proposed))
    error = server.worker_adopt.validate_fleet_api_port(proposed)
    _check(_plan("validation", route="fleet", value=error), "existing")
    error = server.worker_adopt.validate_new_worker_entries(
        server.control_service.read_config(), proposed
    )
    _check(_plan("validation", route="entries", value=error))
    actor = request.headers.get("X-Auth-User", "")
    try:
        action = _plan("request", route="preview")["action"]
        rid = server.control_service.submit(action, proposed, actor)
        result = await server.control_service.wait_result(rid)
    except _NativeFailure:
        raise
    except Exception:
        server.logger.exception("Error submitting control preview")
        return _reply(_plan("error", route="preview", error="submit"))
    return _reply(_plan("complete", route="preview", id=rid, value=result))


async def handle_control_commit(request):
    from mining_dashboard.web import server

    server._require_control_header(request)
    body = await server.config_request(request)
    try:
        actor = request.headers.get("X-Auth-User", "")
        approval = server.approval_envelope(body)
        action = _plan("request", route="commit")["action"]
        rid = server.control_service.submit(
            action,
            actor=actor,
            intent_id=body.get("id"),
            confirm=body.get("confirm"),
            approval=approval,
        )
    except _NativeFailure:
        raise
    except Exception:
        _reply(_plan("error", error="intent"))
    result = await server.control_service.wait_result(
        rid, done=lambda value: _plan("done", value=value.get("status"))["done"]
    )
    return _reply(_plan("complete", route="commit", id=rid, value=result))


async def handle_control_upgrade(request):
    from mining_dashboard.web import server

    server._require_control_header(request)
    try:
        body = await request.json()
    except Exception:
        _reply(_plan("error", error="json"))
    version = body.get("version")
    _check(_plan("version", route="upgrade", version=version))
    try:
        action = _plan("request", route="upgrade")["action"]
        rid = server.control_service.submit(
            action, actor=request.headers.get("X-Auth-User", ""), version=version
        )
    except _NativeFailure:
        raise
    except Exception:
        server.logger.exception("Error submitting control upgrade")
        return _reply(_plan("error", route="upgrade", error="submit"))
    return _reply(_plan("complete", route="upgrade", id=rid))


async def handle_control_os_update(request):
    from mining_dashboard.web import server

    server._require_control_header(request)
    try:
        body = await request.json()
    except Exception:
        _reply(_plan("error", error="json"))
    plan = _plan("os-action", value=body.get("action"))
    _check(plan)
    version = body.get("version")
    _check(_plan("version", route="os-update", version=version))
    try:
        rid = server.control_service.submit(
            plan["action"], actor=request.headers.get("X-Auth-User", ""), version=version
        )
    except _NativeFailure:
        raise
    except Exception:
        server.logger.exception("Error submitting OS-update step")
        return _reply(_plan("error", route="os-update", error="submit"))
    return _reply(_plan("complete", route="os-update", id=rid))


async def handle_control_backup(request):
    from mining_dashboard.web import server

    server._require_control_header(request)
    try:
        action = _plan("request", route="backup")["action"]
        rid = server.control_service.submit(action, actor=request.headers.get("X-Auth-User", ""))
    except _NativeFailure:
        raise
    except Exception:
        server.logger.exception("Error submitting backup request")
        return _reply(_plan("error", route="backup", error="submit"))
    return _reply(_plan("complete", route="backup", id=rid))


async def handle_control_result(request):
    from mining_dashboard.web import server

    try:
        result = server.control_service.result(request.query.get("id", ""))
    except ValueError:
        _reply(_plan("error", error="uuid"))
    return _reply(_plan("complete", route="result", value=result))


def install(server=None):
    from mining_dashboard.web import config_commit

    if server is None:
        from mining_dashboard.web import server

    for name in (
        "_require_control_header",
        "handle_config",
        "handle_control_preview",
        "handle_control_commit",
        "handle_control_upgrade",
        "handle_control_os_update",
        "handle_control_backup",
        "handle_control_result",
    ):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(server, name))
        setattr(server, name, globals()[name])
    for name in ("config_request", "approval_envelope"):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(config_commit, name))
        setattr(config_commit, name, globals()[name])
        setattr(server, name, globals()[name])
    from mining_dashboard import go_worker_http

    go_worker_http.install(server)
