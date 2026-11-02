import json

from aiohttp import web

from mining_dashboard import go_channel
from mining_dashboard.go_wizard_policy import _fields

REFERENCE_FUNCTIONS = {}


def _call(operation, phase, **values):
    return go_channel.call("wizard-submission", {"operation": operation, "phase": phase, **values})


def _execute(result, *, data=None, passphrase=None):
    from mining_dashboard.wizard import server

    for action in result.get("actions", []):
        operation = action["operation"]
        if operation == "clear-host":
            server._spool_clear_host_verdict()
        elif operation == "clear-sidecars":
            server.clear_submission_sidecars()
        elif operation == "remove":
            server.spool_remove(action["name"])
        elif operation == "text":
            server._spool_write_text(action["name"], action["text"])
        elif operation == "json":
            server._spool_write_text(action["name"], json.dumps(dict(action["pairs"])))
        elif operation == "passphrase":
            server._spool_write_text("restore-passphrase", passphrase, server.restore_dir())
        elif operation == "archive":
            directory = server.restore_dir() if action.get("volatile") else None
            server._spool_write_bytes("restore-archive", data, directory)
        else:
            raise RuntimeError("unsupported native wizard submission action")


def _response(result):
    return web.json_response(result["body"], status=result["status"])


def _submit_rig(form):
    from mining_dashboard.wizard import server

    fields = _fields(form, ("rig_pool",))
    fields["rig_pool"]["digit"] = fields["rig_pool"]["text"].rpartition(":")[2].isdigit()
    result = _call("rig", "start", fields=fields)
    if result.get("next") != "install":
        return _response(result)
    stick = server.installer_mode() and str(form.get("disk", "")).strip() == "usb"
    installer = server.installer_mode() and not stick
    fields.update(_fields(form, ("rig_worker", "rig_password", "disk", "confirm", "wipe")))
    result = _call(
        "rig",
        "publish",
        fields=fields,
        installer=installer,
        disks=server._disks() if installer else [],
    )
    _execute(result)
    return _response(result)


async def _submit_restore_locked(request):
    from mining_dashboard.wizard import server

    conflict = server.submission_conflict()
    if conflict is not None:
        return conflict
    form = await request.post()
    upload = form.get("archive")
    result = _call("restore", "start", upload=isinstance(upload, web.FileField))
    _execute(result)
    if result.get("next") != "read-upload":
        return _response(result)
    data = upload.file.read()
    result = _call("restore", "validate", size=len(data), limit=server.RESTORE_MAX_BYTES)
    if result.get("next") != "passphrase":
        return _response(result)
    passphrase = str(form.get("passphrase", ""))
    result = _call("restore", "passphrase", passphrase_bytes=len(passphrase.encode()))
    if result.get("next") != "install":
        return _response(result)
    installer = server.installer_mode()
    result = _call(
        "restore",
        "publish",
        installer=installer,
        fields=_fields(form, ("disk", "confirm", "wipe")) if installer else {},
        disks=server._disks() if installer else [],
        encrypted=data.startswith(b"Salted__"),
    )
    try:
        _execute(result, data=data, passphrase=passphrase)
    except OSError:
        result = _call("failure", "restore", cleaned=server.clear_failed_restore())
    return _response(result)


def install(server):
    for name in ("_submit_rig", "_submit_restore_locked"):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(server, name))
        setattr(server, name, globals()[name])
