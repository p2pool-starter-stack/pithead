from mining_dashboard import go_channel
from mining_dashboard.config.defaults import default_of
from mining_dashboard.go_wizard_config import _tree, _value

REFERENCE_FUNCTIONS = {}


def _plan(phase, **values):
    identities = {}
    payload = {
        name: value if name == "raw" else _tree(value, identities) for name, value in values.items()
    }
    result = go_channel.call("wizard-preparation", {"operation": phase, "phase": phase, **payload})
    if not isinstance(result, dict) or not isinstance(result.get("next"), str):
        raise RuntimeError("invalid native wizard preparation plan")
    floats = {number: value for number, value in identities.values()}
    try:
        for name in ("config", "changes"):
            if name in result:
                result[name] = _value(result[name], floats)
    except (KeyError, TypeError, ValueError) as error:
        raise RuntimeError("invalid native wizard preparation value") from error
    return result


def _next(result, *expected):
    if result["next"] not in expected:
        raise RuntimeError("invalid native wizard preparation phase")


def _prepared(result, next_phase):
    _next(result, next_phase)
    if not isinstance(result.get("config"), dict) or not isinstance(result.get("changes"), list):
        raise RuntimeError("invalid native wizard prepared configuration")
    return result["config"], result["changes"]


def config(form, raw):
    from mining_dashboard.wizard import server

    result = _plan("source", raw=bool(raw))
    _next(result, "parse", "build")
    if result["next"] == "parse":
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
    _next(_plan("object", config=cfg), "prepare")
    return cfg


def prepare(cfg, reference):
    from mining_dashboard import wizard_config
    from mining_dashboard.wizard import server

    reference = reference or {}
    legacy = wizard_config._XVB_ALIAS_V1_DEFAULTS
    cfg, changes = _prepared(
        _plan("prepare", config=cfg, reference=reference, legacy_defaults=legacy), "previous"
    )
    result = _plan("previous", previous=server._last_attempt())
    _next(result, "defaults", "validate")
    if result["next"] == "defaults":
        defaults = server.new_install_defaults(
            (server._spool_read("platform.txt") or "appliance").strip()
        )
        cfg, changes = _prepared(
            _plan(
                "defaults",
                config=cfg,
                reference=reference,
                defaults=defaults,
                legacy_defaults=legacy,
                changes=changes,
            ),
            "validate",
        )
    previous = server._last_attempt()
    host = default_of("dashboard.host", legacy=True)
    dashboard = cfg.get("dashboard", {})
    if isinstance(dashboard, dict) and dashboard.get("host", host) != "auto":
        previous.get("dashboard", {})
    return _prepared(
        _plan("validate", config=cfg, previous=previous, default_host=host, changes=changes),
        "ready",
    )


def install(server=None):
    del server
    from mining_dashboard import go_wizard_typed

    REFERENCE_FUNCTIONS.setdefault("_config", go_wizard_typed._config)
    go_wizard_typed._config = config
