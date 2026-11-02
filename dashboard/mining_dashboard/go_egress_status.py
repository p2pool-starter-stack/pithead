import builtins

from mining_dashboard import go_channel

REFERENCE_FUNCTIONS = {}
PROVIDERS = {}
CONSTANTS = {}
_MAX_INTEGER_BITS = 1000
_STATES = ("enforced", "missing", "unverified")


def _numeric(value):
    if type(value) is int:
        if value.bit_length() > _MAX_INTEGER_BITS:
            return None
        return {"kind": "int", "value": str(value)}
    if type(value) is float:
        return {"kind": "float", "value": repr(value).lower()}
    return {"kind": "invalid"}


def _request(operation, **payload):
    return go_channel.call("network", {"operation": operation, **payload})


def _status_constant_reason(module):
    for name in ("CHECK_INTERVAL_S", "_MAX_EPOCH_S"):
        current = getattr(module, name)
        if type(current) is not int or current != CONSTANTS[name]:
            return "status-constant"
    for name in ("ENFORCED", "MISSING", "UNVERIFIED"):
        current = getattr(module, name)
        if type(current) is not str or current != CONSTANTS[name]:
            return "status-constant"
    missing = module._MISSING_RCS
    if (
        type(missing) is not set
        or any(type(value) is not int for value in missing)
        or missing != CONSTANTS["_MISSING_RCS"]
    ):
        return "status-constant"
    return None


def _plan_constant_reason(module):
    if _status_constant_reason(module):
        return "plan-constant"
    labels = module._LABELS
    if (
        type(labels) is not dict
        or any(type(key) is not str or type(value) is not str for key, value in labels.items())
        or labels != CONSTANTS["_LABELS"]
    ):
        return "plan-label"
    return None


def _loaded_compat(reason, status, now):
    del reason
    from mining_dashboard.service.network import egress_status

    return egress_status._firewall_status_loaded(status, now)


def _result_compat(reason, rc, age):
    del reason
    from mining_dashboard.service.network import egress_status

    return egress_status._firewall_status_result(rc, age)


def _resolved_compat(reason, build, state, knobs):
    del reason
    from mining_dashboard.service.network import egress_status

    return egress_status._with_firewall_state_resolved(build, state, **knobs)


def _loaded_reason(module):
    current_open = module.__dict__.get("open", builtins.open)
    current_abs = module.__dict__.get("abs", builtins.abs)
    for name, current in (
        ("open", current_open),
        ("abs", current_abs),
        ("json-load", module.json.load),
        ("loaded", module._firewall_status_loaded),
        ("result", module._firewall_status_result),
    ):
        if current is not PROVIDERS[name]:
            return name + "-provider"
    return _status_constant_reason(module)


def _clock_reason(module):
    if module.time.time is not PROVIDERS["clock"]:
        return "clock-provider"
    return None


def _valid_reply(value):
    if type(value) is not bool:
        raise RuntimeError("native network returned invalid firewall status validity")
    return value


def _state_reply(value):
    if type(value) is not str or value not in _STATES:
        raise RuntimeError("native network returned invalid firewall state")
    return value


def egress_firewall_state(path=None, now=None):
    from mining_dashboard.service.network import egress_status

    opener = egress_status.__dict__.get("open", builtins.open)
    try:
        with opener(path or egress_status.STATUS_PATH, encoding="utf-8") as stream:
            status = egress_status.json.load(stream)
    except (OSError, ValueError, RecursionError):
        return egress_status.UNVERIFIED
    if reason := _loaded_reason(egress_status):
        return _loaded_compat(reason, status, now)
    rc = status.get("rc") if isinstance(status, dict) else None
    checked_at = status.get("checked_at") if isinstance(status, dict) else None
    rc_meta, checked_meta = _numeric(rc), _numeric(checked_at)
    if rc_meta is None or checked_meta is None:
        return _loaded_compat("wide-integer", status, now)
    valid = _valid_reply(_request("firewall-status-valid", rc=rc_meta, checked_at=checked_meta))
    if not valid:
        return egress_status.UNVERIFIED
    if reason := _clock_reason(egress_status):
        return _loaded_compat(reason, status, now)
    current = egress_status.time.time() if now is None else now
    age = abs(current - checked_at)
    age_meta = _numeric(age)
    if type(age) not in (int, float) or age_meta is None:
        return _result_compat("age-shape", rc, age)
    return _state_reply(_request("firewall-status-result", rc=rc_meta, age=age_meta))


def _plan_reply(value, state):
    if (
        type(value) is not dict
        or tuple(value) != ("firewall", "overlay", "warn", "prefix")
        or any(type(value[field]) is not bool for field in ("firewall", "overlay", "warn"))
        or type(value["prefix"]) is not str
    ):
        raise RuntimeError("native network returned invalid firewall plan")
    expected = {
        "firewall": state == "enforced",
        "overlay": True,
        "warn": state != "enforced",
        "prefix": CONSTANTS["_LABELS"].get(state, "") if state != "enforced" else "",
    }
    if value != expected:
        raise RuntimeError("native network returned inconsistent firewall plan")
    return value


def with_firewall_state(build, *, firewall, state=None, **knobs):
    from mining_dashboard.service.network import egress_status

    if not firewall:
        return build(firewall=False, **knobs)
    provider = egress_status.egress_firewall_state
    provided = bool(state)
    resolved = state if provided else provider()
    if type(firewall) is not bool:
        return _resolved_compat("firewall-shape", build, resolved, knobs)
    if reason := _plan_constant_reason(egress_status):
        return _resolved_compat(reason, build, resolved, knobs)
    if type(resolved) is not str or resolved not in _STATES:
        return _resolved_compat("state-value", build, resolved, knobs)
    if egress_status._with_firewall_state_resolved is not PROVIDERS["resolved"]:
        return _resolved_compat("resolved-provider", build, resolved, knobs)
    plan = _plan_reply(_request("firewall-plan", configured=True, state=resolved), resolved)
    result = build(firewall=plan["firewall"], **knobs)
    summary = result["summary"]
    if plan["overlay"]:
        summary["firewall_state"] = resolved
        if plan["warn"]:
            summary["level"] = "warn"
            summary["label"] = f"{plan['prefix']}; {summary['label']}"
    return result


def install():
    from mining_dashboard.service.network import egress, egress_status, topology

    for name in (
        "CHECK_INTERVAL_S",
        "_MAX_EPOCH_S",
        "ENFORCED",
        "MISSING",
        "UNVERIFIED",
    ):
        CONSTANTS.setdefault(name, getattr(egress_status, name))
    CONSTANTS.setdefault("_MISSING_RCS", set(egress_status._MISSING_RCS))
    CONSTANTS.setdefault("_LABELS", dict(egress_status._LABELS))
    for name, value in (
        ("open", egress_status.__dict__.get("open", builtins.open)),
        ("abs", egress_status.__dict__.get("abs", builtins.abs)),
        ("json-load", egress_status.json.load),
        ("clock", egress_status.time.time),
        ("loaded", egress_status._firewall_status_loaded),
        ("result", egress_status._firewall_status_result),
        ("resolved", egress_status._with_firewall_state_resolved),
    ):
        PROVIDERS.setdefault(name, value)
    for name in ("egress_firewall_state", "with_firewall_state"):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(egress_status, name))
        setattr(egress_status, name, globals()[name])
    egress.with_firewall_state = with_firewall_state
    topology.with_firewall_state = with_firewall_state
