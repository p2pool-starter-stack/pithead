import json

from aiohttp import web

from mining_dashboard import go_channel
from mining_dashboard.go_wizard_config import _tree, _value

REFERENCE_FUNCTIONS = {}


def _plan(phase, **values):
    identities = {}
    plain = {"stage", "installer", "mode", "new_machine"}
    payload = {
        name: value if name in plain else _tree(value, identities) for name, value in values.items()
    }
    result = go_channel.call("wizard-state", {"operation": phase, "phase": phase, **payload})
    expected = {"prepare": "config", "config": "response", "response": "ready"}
    if not isinstance(result, dict) or result.get("next") != expected[phase]:
        raise RuntimeError("invalid native wizard state phase")
    floats = {number: value for number, value in identities.values()}
    try:
        for name in ("attempt", "changes", "config", "body"):
            if name in result:
                result[name] = _value(result[name], floats)
    except (KeyError, TypeError, ValueError) as error:
        raise RuntimeError("invalid native wizard state value") from error
    if phase == "prepare":
        if not isinstance(result.get("attempt"), dict) or not isinstance(
            result.get("changes"), list
        ):
            raise RuntimeError("invalid native wizard state preparation")
        if any(
            type(result.get(name)) is not bool
            for name in ("remember", "read_handoff", "need_defaults")
        ):
            raise RuntimeError("invalid native wizard state decisions")
    elif phase == "config":
        if (
            not isinstance(result.get("config"), dict)
            or type(result.get("new_machine")) is not bool
            or result.get("mode") not in ("setup", "installer")
        ):
            raise RuntimeError("invalid native wizard state configuration")
    elif not isinstance(result.get("body"), dict):
        raise RuntimeError("invalid native wizard state response")
    return result


def build(request):
    from mining_dashboard import wizard_config
    from mining_dashboard.wizard import server

    if not server._authed(request):
        return web.json_response({"error": "unauthenticated"}, status=401)
    reference = server._reference()
    stage = server.wizard_stage()
    prepared = _plan(
        "prepare",
        reference=reference or {},
        attempt=server._last_attempt(),
        legacy_defaults=wizard_config._XVB_ALIAS_V1_DEFAULTS,
        stage=stage,
    )
    remembered, install, auth = server.recovery_state(
        server._spool_json, server._spool_read, server._disks()
    )
    if prepared["remember"]:
        server.remember_changes(
            server.spool_dir(), prepared["changes"], server._spool_json, server._spool_write_text
        )
    budget = server._spool_json("disk-budget.json") or {}
    raw_handoff = (
        server._spool_read("handoff.json", server.handoff_dir())
        if prepared["read_handoff"]
        else None
    )
    installer = server.installer_mode()
    defaults = {}
    if prepared["need_defaults"]:
        defaults = server.new_machine_answers(
            budget, server._disks(), (server._spool_read("platform.txt") or "appliance").strip()
        )
        defaults = defaults or {}
        defaults.items()
    configured = _plan(
        "config",
        reference=dict(reference),
        attempt=prepared["attempt"],
        defaults=defaults,
        installer=installer,
    )
    error = server._spool_read("error.txt")
    disks = server._disks()
    rig_defaults = server._rig_defaults()
    data_wiped = server._data_wiped()
    handoff = json.loads(raw_handoff) if raw_handoff else None
    saved_role = server._saved_role()
    node_probe = server.saved_probe(server._spool_json)
    result = _plan(
        "response",
        stage=stage,
        mode=configured["mode"],
        config=configured["config"],
        reference=reference,
        new_machine=configured["new_machine"],
        budget=budget,
        error=error,
        disks=disks,
        rig_defaults=rig_defaults,
        data_wiped=data_wiped,
        handoff=handoff,
        saved_role=saved_role,
        node_probe=node_probe,
        changes=prepared["changes"],
        remembered=remembered,
        install_attempt=install,
        auth_mode=auth,
        restore_enabled=request.app["restore_enabled"],
    )
    return web.json_response(result["body"], headers={"Cache-Control": "no-store"})


def install(server=None):
    del server
    from mining_dashboard import go_wizard

    REFERENCE_FUNCTIONS.setdefault("wizard_state", go_wizard._REFERENCE_STATE)
