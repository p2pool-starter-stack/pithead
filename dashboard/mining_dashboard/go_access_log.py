import math

from mining_dashboard.go_polling import _audit_text
from mining_dashboard.go_wizard_config import _call, _value

REFERENCE_FUNCTIONS = {}
PROVIDERS = {}
_FIELDS = ("available", "entries", "failures_24h", "last_failure_ts", "rotate_hint")
_ENTRY_FIELDS = ("ts", "status", "method", "uri", "user")
_NUMERIC_INPUTS = (type(None), bool, int, float, str, list, dict)
_NATIVE_MAX_ROWS = 100_000


def _plain_text(value) -> bool:
    pending, seen = [value], set()
    while pending:
        item = pending.pop()
        if type(item) in (str, float, bool, type(None)):
            continue
        if type(item) is int:
            if item.bit_length() > 1000:
                return False
            continue
        if type(item) not in (list, dict) or id(item) in seen:
            return False
        seen.add(id(item))
        if type(item) is dict:
            if any(type(key) is not str for key in item):
                return False
            pending.extend(item.values())
        else:
            pending.extend(item)
    return True


def _native_rows(raw):
    if type(raw) not in (list, tuple):
        return False
    for entry in raw:
        if type(entry) is not dict or any(type(key) is not str for key in entry):
            return False
        request = entry.get("request")
        if isinstance(request, dict):
            if type(request) is not dict or any(type(key) is not str for key in request):
                return False
        else:
            request = {}
        for field in ("ts", "status", "pithead_probe"):
            value = entry.get(field)
            if (
                type(value) not in _NUMERIC_INPUTS
                or type(value) is int
                and value.bit_length() > 1000
            ):
                return False
        method = request.get("method")
        if isinstance(method, str) and type(method) is not str:
            return False
        if not _plain_text(request.get("uri")) or not _plain_text(entry.get("user_id")):
            return False
    return True


def _access_compat(reason, raw, limit, now):
    from mining_dashboard.service import audit_service

    del reason
    return audit_service._access_summary_rows(raw, limit, now)


def _selection_reason(raw, limit, now, threshold, methods):
    from mining_dashboard.service import audit_service

    if type(raw) in (list, tuple) and len(raw) > _NATIVE_MAX_ROWS:
        return "retained-row-count"
    if any(
        getattr(audit_service, name) is not PROVIDERS[name] for name in ("_clean", "_SAFE_CHARS")
    ):
        return "sanitizer-provider"
    if any(
        audit_service.__dict__.get(name, provider) is not provider
        for name, provider in (("float", float), ("int", int))
    ):
        return "numeric-provider"
    if audit_service.__dict__.get("str", str) is not str:
        return "text-provider"
    if audit_service.math.isfinite is not PROVIDERS["isfinite"]:
        return "finite-provider"
    if type(methods) not in (set, frozenset) or any(type(method) is not str for method in methods):
        return "method-provider"
    if (
        type(limit) not in (type(None), bool, int)
        or type(limit) is int
        and limit.bit_length() > 1000
    ):
        return "slice-limit"
    if type(now) not in (bool, int, float) or type(now) is int and now.bit_length() > 1023:
        return "clock-value"
    if (
        type(threshold) not in (bool, int, float)
        or type(threshold) is int
        and threshold.bit_length() > 1000
    ):
        return "rotation-threshold"
    return None if _native_rows(raw) else "row-shape"


def _summary(available, source_rows=None, **arguments):
    result, identities = _call("audit-access", config={"available": available, **arguments})
    try:
        summary = _value(result, identities)
    except (KeyError, TypeError, ValueError, RuntimeError) as error:
        raise RuntimeError("native access log returned invalid data") from error
    if not isinstance(summary, dict) or tuple(summary) != _FIELDS:
        raise RuntimeError("native access log returned invalid fields")
    rows, count, last = summary["entries"], summary["failures_24h"], summary["last_failure_ts"]
    if (
        type(summary["available"]) is not bool
        or summary["available"] is not available
        or type(summary["rotate_hint"]) is not bool
        or not isinstance(rows, list)
        or type(count) is not int
        or not 0 <= count <= len(source_rows or [])
        or last is not None
        and (type(last) is not float or not math.isfinite(last))
        or (last is None) != (count == 0)
        or len(rows) > len(source_rows or [])
    ):
        raise RuntimeError("native access log returned invalid summary")
    methods = arguments.get("methods", [])
    for row in rows:
        if (
            not isinstance(row, dict)
            or tuple(row) != _ENTRY_FIELDS
            or type(row["ts"]) is not float
            or not math.isfinite(row["ts"])
            or type(row["status"]) is not int
            or row["status"] != 0
            and not 100 <= row["status"] <= 599
            or type(row["method"]) is not str
            or row["method"] not in ["?", *methods]
            or any(
                type(row[field]) is not str
                or len(row[field]) > cap
                or PROVIDERS["_SAFE_CHARS"].search(row[field])
                for field, cap in (("uri", 200), ("user", 64))
            )
        ):
            raise RuntimeError("native access log returned invalid entries")
    if not available and summary != {
        "available": False,
        "entries": [],
        "failures_24h": 0,
        "last_failure_ts": None,
        "rotate_hint": False,
    }:
        raise RuntimeError("native access log returned invalid availability")
    return summary


def access_summary(limit=50, now=None):
    from mining_dashboard.service import audit_service

    raw = audit_service.access_rows(audit_service.config.ACCESS_LOG_PATH)
    if raw is None:
        return _summary(False)
    now = audit_service.time.time() if now is None else now
    threshold, methods = audit_service.ROTATE_HINT_401S, audit_service._KNOWN_METHODS
    reason = _selection_reason(raw, limit, now, threshold, methods)
    if reason:
        return _access_compat(reason, raw, limit, now)
    entries = []
    for entry in raw:
        request = entry.get("request")
        request = request if isinstance(request, dict) else {}
        try:
            ts = float(entry.get("ts") or 0)
        except (TypeError, ValueError, OverflowError):
            ts = 0.0
        try:
            status = int(entry.get("status") or 0)
        except (TypeError, ValueError, OverflowError):
            status = 0
        if status.bit_length() > 1000:
            return _access_compat("wide-status", raw, limit, now)
        method, probe = request.get("method"), entry.get("pithead_probe")
        entries.append(
            {
                "ts": ts,
                "status": status,
                "method": method if isinstance(method, str) else None,
                "uri": _audit_text(request.get("uri")),
                "user": _audit_text(entry.get("user_id")),
                "probe": probe if isinstance(probe, str) else None,
            }
        )
    return _summary(
        True,
        entries,
        entries=entries,
        now=now,
        limit=limit,
        threshold=threshold,
        methods=sorted(methods),
    )


def install():
    from mining_dashboard.service import audit_service

    for name in ("_clean", "_SAFE_CHARS"):
        PROVIDERS.setdefault(name, getattr(audit_service, name))
    PROVIDERS.setdefault("isfinite", audit_service.math.isfinite)
    REFERENCE_FUNCTIONS.setdefault("access_summary", audit_service.access_summary)
    audit_service.access_summary = access_summary
