import json

from aiohttp import web

from mining_dashboard import go_channel
from mining_dashboard.go_wizard_config import _tree, _value
from mining_dashboard.go_wizard_policy import _fields
from mining_dashboard.go_wizard_submission import _execute as _basic_actions
from mining_dashboard.go_wizard_submission import _response

REFERENCE_FUNCTIONS = {}


def _call(phase, **values):
    return go_channel.call("wizard-typed", {"phase": phase, **values})


def _execute(result, *, cfg=None, ref=None, changes=None, report=None):
    from mining_dashboard.wizard import server

    for action in result.get("actions", []):
        operation = action["operation"]
        if operation == "report":
            server._spool_write_text("node-probe.json", json.dumps(report))
        elif operation == "remember":
            server.remember_changes(
                server.spool_dir(), changes, server._spool_json, server._spool_write_text
            )
        elif operation == "attempt":
            server._spool_write_text("last-attempt.json", json.dumps(cfg))
        elif operation == "config":
            server._spool_write_config(server.explicit_wizard_config(cfg, ref))
        else:
            _basic_actions({"actions": [action]})


def _next(result, expected):
    if result.get("next") != expected:
        raise RuntimeError("invalid native wizard typed submission phase")


def _config(form, raw):
    from mining_dashboard.wizard import server

    if raw:
        cfg = server.documents.loads(raw)
        server.documents.reject_placeholders(cfg)
    else:
        cfg = server.build_config(
            dict(form),
            platform=(server._spool_read("platform.txt") or "appliance").strip(),
            tari_default=server.tari_disk_default(
                server._spool_json("disk-budget.json") or {},
                server._disks(),
                str(form.get("disk", "")),
                str(form.get("wipe", "keep")),
            ),
        )
    if not isinstance(cfg, dict):
        raise ValueError("the top level must be a JSON object")
    return cfg


async def _submit_locked(request):
    from mining_dashboard.wizard import server

    form = await request.post()
    result = _call("start", fields=_fields(form, ("disk",)))
    _execute(result)
    _next(result, "route")
    raw = str(form.get("config", "")).strip()
    ref = server._reference()
    installer = server.installer_mode()
    fields = _fields(form, ("disk", "wipe", "role", "confirm"))
    fields["wipe"]["text"] = str(form.get("wipe", "")).strip()
    result = _call("route", fields=fields, installer=installer)
    if result.get("next") == "keep":
        result = _call("keep", fields=fields, disks=server._disks())
        _execute(result)
    if result.get("status"):
        return _response(result)
    if result.get("next") == "rig":
        return server._submit_rig(dict(form))
    _next(result, "config")
    try:
        cfg = _config(form, raw)
    except server.documents.ConfigDocumentError as error:
        return web.json_response({"error": error.diagnostic()}, status=400)
    except (ValueError, TypeError):
        return web.json_response({"error": "Not valid JSON: enter a JSON object."}, status=400)
    try:
        cfg, changes = server.prepare_config(cfg, ref, reject_legacy_conflicts=True)
        if not server._last_attempt():
            defaults, _ = server.prepare_config(
                server.new_install_defaults(
                    (server._spool_read("platform.txt") or "appliance").strip()
                ),
                ref,
            )
            cfg = server.deep_merge(defaults, cfg)
        server.validate_machine_name(cfg, server._last_attempt())
    except ValueError as error:
        return web.json_response({"error": f"Invalid configuration: {error}"}, status=400)
    result = _call("prepared", fields=_fields(form, ("auth_mode",)))
    _execute(result)
    _next(result, "install")
    installer = server.installer_mode()
    result = _call(
        "install",
        installer=installer,
        fields=_fields(dict(form), ("disk", "confirm", "wipe")) if installer else {},
        disks=server._disks() if installer else [],
    )
    if result.get("status"):
        return _response(result)
    _next(result, "probe")
    install = result.get("install")
    report = await server.probe_remote_nodes(cfg)
    result = _call("report", configured=bool(report["configured"]))
    _execute(result, report=report)
    _next(result, "verdict")
    result = _call("verdict", probe_ok=bool(report["ok"]), install=install)
    _execute(result, cfg=cfg, ref=ref, changes=changes)
    if result.get("next") == "failure":
        identities = {}
        result = _call("failure", failure=_tree(server.first_failure(report), identities))
        floats = {number: value for number, value in identities.values()}
        result["body"]["error"] = _value(result["body"]["error"], floats)
        if result.get("include_report"):
            result["body"]["node_probe"] = report
        else:
            raise RuntimeError("native wizard failure omitted its probe report")
    else:
        _next(result, "accepted")
        result = _call("accepted", config=_tree(cfg, {}), changes=_tree(changes, {}))
        result["body"]["config_changes"] = _value(result["body"]["config_changes"], {})
    return _response(result)


def install(server):
    REFERENCE_FUNCTIONS.setdefault("_submit_locked", server._submit_locked)
    server._submit_locked = _submit_locked
