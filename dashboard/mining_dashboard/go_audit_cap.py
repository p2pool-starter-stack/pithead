from collections import OrderedDict
from types import FunctionType

from mining_dashboard import go_channel

REFERENCE_FUNCTIONS = {}
COMPAT_FUNCTIONS = {}
NATIVE_FUNCTIONS = {}
_CACHE = OrderedDict()
_MAX_CACHE = 16
_MAX_LIMIT = 4096


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


def _canonical_limit(value):
    return type(value) is int and 0 <= value <= _MAX_LIMIT


def _plan(limit):
    if limit in _CACHE:
        _CACHE.move_to_end(limit)
        return _CACHE[limit]
    result = go_channel.call("network", {"operation": "audit-cap-policy", "limit": limit})
    if (
        type(result) is not dict
        or set(result) != {"limit", "names_full", "spend"}
        or type(result["limit"]) is not int
        or result["limit"] != limit
        or type(result["names_full"]) is not list
        or len(result["names_full"]) != limit + 2
        or any(type(value) is not bool for value in result["names_full"])
        or type(result["spend"]) is not list
        or len(result["spend"]) != limit + 2
        or any(
            type(pair) is not list
            or len(pair) != 2
            or any(type(value) is not bool for value in pair)
            for pair in result["spend"]
        )
    ):
        raise RuntimeError("native network returned invalid audit cap policy")
    plan = tuple(result["names_full"]), tuple(tuple(pair) for pair in result["spend"])
    _CACHE[limit] = plan
    _CACHE.move_to_end(limit)
    while len(_CACHE) > _MAX_CACHE:
        _CACHE.popitem(last=False)
    return plan


def _names_compat(reason, live_names, max_names):
    del reason
    return COMPAT_FUNCTIONS["_names_full"](live_names, max_names)


def _names_full(live_names, max_names):
    if type(live_names) is not int or live_names < 0 or not _canonical_limit(max_names):
        return _names_compat("value", live_names, max_names)
    names_full, _spend = _plan(max_names)
    return names_full[min(live_names, max_names + 1)]


def _count_compat(reason, count):
    del reason
    return COMPAT_FUNCTIONS["_count_policy"](count)


def _count_policy(count):
    from mining_dashboard.service import data_audit

    if "_RIG_EDIT_CAP_PER_HOUR" not in data_audit.__dict__:
        return _count_compat("limit", count)
    cap = data_audit.__dict__["_RIG_EDIT_CAP_PER_HOUR"]
    if type(count) is not int or count < 0 or not _canonical_limit(cap):
        return _count_compat("value", count)
    _names_full_plan, spend = _plan(cap)
    allowed, first_over = spend[min(count, cap + 1)]
    return allowed, first_over


def admit_worker(svc, worker, now, window_sec):
    return NATIVE_FUNCTIONS["admit_worker"](svc, worker, now, window_sec)


def _rig_edit_within_cap(self, worker, now):
    return NATIVE_FUNCTIONS["_rig_edit_within_cap"](self, worker, now)


def install():
    from mining_dashboard.service import data_audit
    from mining_dashboard.service.workers import worker_change_audit

    for module, name, native in (
        (worker_change_audit, "_names_full", _names_full),
        (data_audit, "_count_policy", _count_policy),
    ):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(module, name))
        COMPAT_FUNCTIONS.setdefault(name, _clone(getattr(module, name)))
        setattr(module, name, native)
    for owner, name, native in (
        (worker_change_audit, "admit_worker", admit_worker),
        (data_audit.DataAuditMixin, "_rig_edit_within_cap", _rig_edit_within_cap),
    ):
        method = getattr(owner, name)
        REFERENCE_FUNCTIONS.setdefault(name, method)
        NATIVE_FUNCTIONS.setdefault(name, _clone(method))
        setattr(owner, name, native)
