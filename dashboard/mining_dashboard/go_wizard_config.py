import base64
import math

from mining_dashboard import go_channel
from mining_dashboard.config.defaults import default_of

REFERENCE_FUNCTIONS = {}


def _string(value):
    if any(0xD800 <= ord(char) <= 0xDFFF for char in value):
        encoded = base64.b64encode(value.encode("utf-8", "surrogatepass")).decode("ascii")
        return ["str-bytes", encoded]
    return ["str", value]


def _tree(value, identities):
    if value is None:
        return ["null", None]
    if isinstance(value, bool):
        return ["bool", value]
    if isinstance(value, int):
        return ["int", str(value)]
    if isinstance(value, float):
        identity = 0
        if math.isnan(value):
            identity = identities.setdefault(id(value), (len(identities) + 1, value))[0]
        return ["float", repr(value), identity]
    if isinstance(value, str):
        return _string(value)
    if isinstance(value, list):
        return ["list", [_tree(item, identities) for item in value]]
    if isinstance(value, dict):
        return [
            "dict",
            [
                [
                    _string(key) if any(0xD800 <= ord(char) <= 0xDFFF for char in key) else key,
                    _tree(item, identities),
                ]
                for key, item in value.items()
            ],
        ]
    raise TypeError("wizard configuration values must be JSON values")


def _value(tree, identities):
    kind, value = tree[:2]
    if kind in ("null", "bool", "str"):
        return value
    if kind == "str-bytes":
        return base64.b64decode(value).decode("utf-8", "surrogatepass")
    if kind == "int":
        return int(value)
    if kind == "float":
        if len(tree) > 2 and tree[2]:
            return identities[tree[2]]
        return float(value)
    if kind == "list":
        return [_value(item, identities) for item in value]
    if kind == "dict":
        return {
            _value(key, identities) if isinstance(key, list) else key: _value(item, identities)
            for key, item in value
        }
    raise RuntimeError("native wizard configuration returned an invalid value")


def _call(operation, **values):
    identities = {}
    payload = {key: _tree(value, identities) for key, value in values.items() if key != "reject"}
    if "reject" in values:
        payload["reject"] = values["reject"]
    result = go_channel.call("wizard-config", {"operation": operation, **payload})
    floats = {number: value for number, value in identities.values()}
    return result, floats


def prepare_config(cfg, reference, *, reject_legacy_conflicts=False):
    from mining_dashboard import wizard_config

    if not isinstance(cfg, dict):
        cfg.pop("config_version", None)
    reference = reference or {}
    result, identities = _call(
        "prepare",
        config=cfg,
        reference=reference,
        legacy_defaults=wizard_config._XVB_ALIAS_V1_DEFAULTS,
        reject=reject_legacy_conflicts,
    )
    return _value(result["config"], identities), _value(result["changes"], identities)


def deep_merge(base, over):
    base = dict(base)
    over = over or {}
    over.items()
    result, identities = _call("merge", base=base, over=over)
    return _value(result, identities)


def _check_strip_shapes(cfg, ref):
    cfg = cfg or {}
    _ = cfg.items()
    if isinstance(ref, dict):
        return cfg
    for key, value in cfg.items():
        if key.startswith("_"):
            continue
        if isinstance(value, dict):
            ref.get(key)
        if key in ref:
            ref[key]
    return cfg


def strip_defaults(cfg, ref):
    cfg = _check_strip_shapes(cfg, ref)
    result, identities = _call("strip", config=cfg, reference=ref)
    return _value(result, identities)


def validate_machine_name(cfg, previous):
    dashboard = cfg.get("dashboard", {})
    if not isinstance(dashboard, dict):
        raise ValueError("dashboard must be an object")
    default_host = default_of("dashboard.host", legacy=True)
    host = dashboard.get("host", default_host)
    if host != "auto":
        previous.get("dashboard", {})
    _call(
        "name",
        config=cfg,
        previous=previous,
        default_host=default_host,
    )


def recovery_state(spool_json, spool_read, disks):
    changes = spool_json("config-changes.json")
    changes.get("changes", [])
    attempt = spool_json("install-attempt.json")
    offered = {disk["name"] for disk in disks}
    disk = attempt.get("disk")
    attempt.get("wipe")
    _ = disk in offered
    mode = spool_read("auth-mode")
    result, identities = _call("recovery", changes=changes, attempt=attempt, disks=disks, mode=mode)
    return (
        _value(result["remembered"], identities),
        _value(result["attempt"], identities),
        result["mode"],
    )


def install(server):
    from mining_dashboard import wizard_config, wizard_recovery

    for name in ("prepare_config", "deep_merge", "strip_defaults", "validate_machine_name"):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(wizard_config, name))
        setattr(wizard_config, name, globals()[name])
        if hasattr(server, name):
            setattr(server, name, globals()[name])
    REFERENCE_FUNCTIONS.setdefault("recovery_state", wizard_recovery.recovery_state)
    wizard_recovery.recovery_state = recovery_state
    server.recovery_state = recovery_state
