import math

from mining_dashboard.go_wizard_config import _call, _value

REFERENCE_FUNCTIONS = {}
PROVIDERS = {}
_SCALARS = (str, int, float, bool, type(None))


def _result(operation, **values):
    result, identities = _call("audit-" + operation, config=values)
    try:
        return _value(result, identities)
    except (KeyError, TypeError, ValueError, RuntimeError) as error:
        raise RuntimeError("native audit query returned invalid data") from error


def _indices(operation, count, **values):
    indices = _result(operation, **values)
    if (
        not isinstance(indices, list)
        or any(type(index) is not int or not 0 <= index < count for index in indices)
        or len(set(indices)) != len(indices)
        or operation != "merge"
        and indices != sorted(indices)
    ):
        raise RuntimeError("native audit query returned invalid selection")
    return indices


def _filter_compat(entries, frm, to, q):
    from mining_dashboard.service import audit_service

    ql = (q or "").lower()
    result = []
    for entry in entries:
        if frm is not None or to is not None:
            epoch = audit_service._entry_epoch(entry.get("ts"))
            if epoch is None:
                continue
            if frm is not None and epoch < frm:
                continue
            if to is not None and epoch >= to:
                continue
        if ql and not any(ql in str(value).lower() for value in entry.values()):
            continue
        result.append(entry)
    return result


def filter_log_entries(entries, frm=None, to=None, q=None):
    from mining_dashboard.service import audit_service

    window = frm is not None or to is not None
    if (
        type(entries) not in (list, tuple)
        or any(value is not None and type(value) not in (bool, int, float) for value in (frm, to))
        or q is not None
        and type(q) is not str
        or window
        and audit_service._entry_epoch is not PROVIDERS["epoch"]
        or (window or q)
        and any(type(entry) is not dict for entry in entries)
        or q
        and any(
            type(value) not in _SCALARS or type(value) is int and value.bit_length() > 1000
            for entry in entries
            for value in entry.values()
        )
        or window
        and any(
            type(entry.get("ts")) is int and entry["ts"].bit_length() > 1023 for entry in entries
        )
    ):
        return _filter_compat(entries, frm, to, q)
    ql = (q or "").lower()
    rows = list(entries)
    captured = [entry.copy() if type(entry) is dict else entry for entry in rows]
    epochs = (
        [audit_service._entry_epoch(entry.get("ts")) for entry in captured]
        if window
        else [None] * len(rows)
    )
    fields = (
        [[str(value).lower() for value in entry.values()] for entry in captured]
        if ql
        else [[] for _ in rows]
    )
    selected = _indices(
        "filter", len(rows), epochs=epochs, fields=fields, query=ql, **{"from": frm, "to": to}
    )
    return [rows[index] for index in selected]


def _merge_compat(database, read, identifiers=None):
    if identifiers is None:
        merged = {entry["id"]: entry for entry in database if entry.get("id")}
    else:
        merged = {
            identifier: entry
            for identifier, entry in zip(identifiers, database, strict=True)
            if identifier
        }
    for entry in read():
        identifier = entry.get("id")
        if identifier and identifier not in merged:
            merged[identifier] = {**entry, "source": "control"}
        elif not identifier:
            merged[f"log-{id(entry)}"] = {**entry, "source": "control"}
    return sorted(merged.values(), key=lambda entry: entry.get("ts", ""), reverse=True)


def _merge_shape(rows):
    return type(rows) in (list, tuple) and all(
        type(row) is dict and type(row.get("id", "")) is str and type(row.get("ts", "")) is str
        for row in rows
    )


def _merged_audit_entries(state_mgr):
    from mining_dashboard.service import audit_service

    database = state_mgr.get_audit_events()
    if not _merge_shape(database):
        return _merge_compat(database, audit_service.recent_changes)
    database = list(database)
    identifiers = [row.get("id", "") for row in database]
    live = audit_service.recent_changes()
    if not _merge_shape(database) or not _merge_shape(live):
        return _merge_compat(database, lambda: live, identifiers)
    originals = database + list(live)
    rows = database + [{**row, "source": "control"} for row in live]
    projection = [
        {
            "id": identifiers[index] if index < len(database) else row.get("id", ""),
            "ts": row.get("ts", ""),
            "control": index >= len(database),
            "synthetic": str(id(originals[index])),
        }
        for index, row in enumerate(rows)
    ]
    selected = _indices("merge", len(rows), rows=projection)
    return [rows[index] for index in selected]


def _log_filters(request):
    query = (request.query.get("q") or "").strip()

    def number(name) -> float | None:
        value = request.query.get(name)
        if value in (None, ""):
            return None
        try:
            return float(value)
        except ValueError:
            return None

    result = _result("query", **{"from": number("from"), "to": number("to"), "query": query})
    if (
        not isinstance(result, list)
        or len(result) != 3
        or any(
            value is not None and (type(value) is not float or not math.isfinite(value))
            for value in result[:2]
        )
        or result[2] is not None
        and (type(result[2]) is not str or not result[2] or len(result[2]) > 200)
    ):
        raise RuntimeError("native audit query returned invalid filters")
    return tuple(result)


def install():
    from mining_dashboard.service import audit_service
    from mining_dashboard.web import server

    PROVIDERS.setdefault("epoch", audit_service._entry_epoch)
    for module, names in (
        (audit_service, ("filter_log_entries",)),
        (server, ("_merged_audit_entries", "_log_filters")),
    ):
        for name in names:
            REFERENCE_FUNCTIONS.setdefault(name, getattr(module, name))
            setattr(module, name, globals()[name])
