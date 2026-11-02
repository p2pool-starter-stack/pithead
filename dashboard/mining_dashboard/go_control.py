import base64
import json

from mining_dashboard import go_channel
from mining_dashboard.config import config


def write(request):
    rid = request["id"]
    go_channel.call(
        "control",
        {
            "operation": "control-write",
            "directory": config.CONTROL_REQUESTS_DIR,
            "id": str(rid),
            "data": base64.b64encode(json.dumps(request).encode()).decode(),
        },
    )
    return rid


def _submit(**payload):
    from mining_dashboard.service import request_spool

    pairs = go_channel.call("control", {"operation": "control-submit", **payload})
    return request_spool.write(dict(pairs))


def submit(action, cfg=None, actor="", intent_id=None, version=None, confirm=None, approval=None):
    return _submit(
        action=action,
        config=cfg,
        actor=actor,
        id=intent_id or "",
        version=version,
        confirm=confirm,
        approval=approval,
    )


def submit_worker_apply(worker, changes, actor="", intent_id=None):
    return _submit(
        kind="worker-apply", worker=worker, changes=changes, actor=actor, id=intent_id or ""
    )


def submit_worker_upgrade(worker, version, actor="", intent_id=None):
    return _submit(
        kind="worker-upgrade", worker=worker, version=version, actor=actor, id=intent_id or ""
    )


def validate_worker_changes(changes):
    return go_channel.call("control", {"operation": "control-validate-worker", "changes": changes})


def result(rid) -> dict | None:
    raw = go_channel.call(
        "control",
        {"operation": "control-result", "directory": config.CONTROL_RESULTS_DIR, "id": rid},
    )
    try:
        return json.loads(raw) if raw is not None else None
    except json.JSONDecodeError:
        return None


def install():
    from mining_dashboard import (
        go_access_log,
        go_audit_query,
        go_control_http,
        go_documents,
        go_editor,
        go_polling,
        go_preserve,
        go_rigforge,
        go_state,
    )
    from mining_dashboard.service import control_service, request_spool

    go_documents.install()
    go_polling.install()
    go_audit_query.install()
    go_access_log.install()
    go_rigforge.install()
    go_preserve.install()
    go_editor.install()
    go_state.install()
    go_control_http.install()
    request_spool.write = write
    for name in (
        "submit",
        "submit_worker_apply",
        "submit_worker_upgrade",
        "validate_worker_changes",
        "result",
    ):
        setattr(control_service, name, globals()[name])
