import builtins
from functools import lru_cache
from types import FunctionType

from mining_dashboard import go_channel

REFERENCE_FUNCTIONS = {}
COMPAT_FUNCTIONS = {}
_MAX_TOKEN_LEN = 64
_OTHER_TYPES = (type(None), bool, int, float, list, dict, tuple, bytes)
_STATE = {}


def _clone(function):
    value = FunctionType(
        function.__code__,
        function.__globals__,
        function.__name__,
        function.__defaults__,
        function.__closure__,
    )
    value.__kwdefaults__ = function.__kwdefaults__
    value.__dict__.update(function.__dict__)
    return value


def _compat(reason, meta):
    del reason
    return COMPAT_FUNCTIONS["parse_config_meta"](meta)


def _provider_reason(module):
    if module.__dict__.get("_token") is not _STATE["_token"]:
        return "token-provider"
    if (
        module.__dict__.get("_TOKEN_RE") is not _STATE["_TOKEN_RE"]
        or module.__dict__.get("_TS_RE") is not _STATE["_TS_RE"]
    ):
        return "regex-provider"
    if module.__dict__.get("CONFIG_SOURCES") is not _STATE["CONFIG_SOURCES"]:
        return "sources"
    limit = module.__dict__.get("_MAX_TOKEN_LEN")
    if type(limit) is not int or limit != _MAX_TOKEN_LEN:
        return "token-limit"
    for name in ("isinstance", "len", "any", "dict", "str"):
        expected = getattr(builtins, name)
        if module.__dict__.get(name, expected) is not expected:
            return "builtin-provider"
    return None


def _field(value):
    if type(value) is str:
        length = min(len(value), _MAX_TOKEN_LEN + 1)
        if length > _MAX_TOKEN_LEN:
            return {"kind": "string", "length": length}
        if any(0xD800 <= ord(char) <= 0xDFFF for char in value):
            return None
        field = {"kind": "string", "length": length}
        field["value"] = value
        return field
    if type(value) in _OTHER_TYPES:
        return {"kind": "other"}
    return None


@lru_cache(maxsize=256)
def _native_plan(key):
    names = ("source", "revision", "changed_at", "last_change_id")
    fields = {}
    for name, (kind, length, value) in zip(names, key, strict=True):
        field = {"kind": kind}
        if length is not None:
            field["length"] = length
        if value is not None:
            field["value"] = value
        fields[name] = field
    result = go_channel.call(
        "fleet",
        {
            "operation": "config_meta_policy",
            "args": [fields],
            "now": 0,
            "zone": "",
            "envelope": True,
        },
    )
    result_names = ("revision", "changed_at", "source", "last_change_id")
    if (
        type(result) is not dict
        or set(result) != set(result_names)
        or any(type(result[name]) is not bool for name in result_names)
    ):
        raise RuntimeError("native fleet returned invalid config metadata policy")
    return tuple(result[name] for name in result_names)


def _plan(fields):
    key = tuple(
        (field["kind"], field.get("length"), field.get("value")) for field in fields.values()
    )
    return _native_plan(key)


def parse_config_meta(meta):
    from mining_dashboard.client import rig_config_meta

    if type(meta) is not dict:
        return _compat("container", meta)
    if any(type(key) is not str for key in meta):
        return _compat("key", meta)
    if reason := _provider_reason(rig_config_meta):
        return _compat(reason, meta)
    values = {
        "source": meta.get("source"),
        "revision": meta.get("revision"),
        "changed_at": meta.get("changed_at"),
        "last_change_id": meta.get("last_change_id"),
    }
    fields = {name: _field(values[name]) for name in values}
    if any(field is None for field in fields.values()):
        return _compat("value", meta)
    accepted = dict(
        zip(("revision", "changed_at", "source", "last_change_id"), _plan(fields), strict=True)
    )
    out = {name: values[name] if accepted[name] else None for name in accepted}
    return out if any(out.values()) else None


def install():
    from mining_dashboard.client import rig_config_meta, xmrig_client
    from mining_dashboard.service.workers import worker_change_audit

    reference = REFERENCE_FUNCTIONS.setdefault(
        "parse_config_meta", rig_config_meta.parse_config_meta
    )
    COMPAT_FUNCTIONS.setdefault("parse_config_meta", _clone(reference))
    if not _STATE:
        _STATE.update(
            _token=rig_config_meta._token,
            _TOKEN_RE=rig_config_meta._TOKEN_RE,
            _TS_RE=rig_config_meta._TS_RE,
            CONFIG_SOURCES=rig_config_meta.CONFIG_SOURCES,
        )
    rig_config_meta.parse_config_meta = parse_config_meta
    xmrig_client.parse_config_meta = parse_config_meta
    worker_change_audit.parse_config_meta = parse_config_meta
