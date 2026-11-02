import json
from collections import OrderedDict
from contextvars import ContextVar
from types import FunctionType

from mining_dashboard import go_channel

REFERENCE_FUNCTIONS = {}
COMPAT_FUNCTIONS = {}
NATIVE_FUNCTIONS = {}
PROVIDERS = {}
_SCOPE = ContextVar("go_control_outcomes_scope", default=None)
_REFERENCE_ONLY = ContextVar("go_control_outcomes_reference_only", default=False)
_MAX_ROWS = 256
_MAX_TERMINAL = 64
_MAX_TEXT_BYTES = 256
_MAX_REQUEST_BYTES = 2 << 20
_MAX_CACHE = 512
_MAX_LOOKAHEAD = 4096
_MAX_MAPPING_KEYS = 128


def _clone(function, globals_=None):
    value = FunctionType(
        function.__code__,
        globals_ or function.__globals__,
        function.__name__,
        function.__defaults__,
        function.__closure__,
    )
    value.__kwdefaults__ = function.__kwdefaults__
    value.__dict__.update(function.__dict__)
    return value


def _utf8_within(value, limit):
    if len(value) > limit:
        return False
    if any(0xD800 <= ord(char) <= 0xDFFF for char in value):
        return False
    return len(value.encode()) <= limit


def _vocabulary(value):
    if (
        type(value) not in (tuple, list)
        or len(value) > _MAX_TERMINAL
        or any(type(item) is not str or not _utf8_within(item, _MAX_TEXT_BYTES) for item in value)
    ):
        return None
    return tuple(value)


def _dict_keys(value):
    return (
        type(value) is dict
        and len(value) <= _MAX_MAPPING_KEYS
        and all(type(key) is str for key in value)
    )


def _metadata(change_id, status):
    if type(change_id) is str:
        id_string, id_nonempty = True, bool(change_id)
    else:
        id_string, id_nonempty = False, False
    if type(status) is str:
        if not _utf8_within(status, _MAX_TEXT_BYTES):
            return None
        return id_string, id_nonempty, "string", status
    return id_string, id_nonempty, "other", None


def _native_status(status):
    return type(status) in (str, type(None), bool, int, float)


def _row(key):
    id_string, id_nonempty, kind, status, _terminal = key
    row = {
        "id_string": id_string,
        "id_nonempty": id_nonempty,
        "status_kind": kind,
    }
    if kind == "string":
        row["status"] = status
    return row


def _native(keys, terminal):
    payload = {
        "operation": "control-outcomes",
        "rows": [_row(key) for key in keys],
        "terminal": list(terminal),
    }
    if len(json.dumps(payload).encode()) + 1 > _MAX_REQUEST_BYTES:
        raise RuntimeError("native control outcome request exceeds size limit")
    result = go_channel.call("network", payload)
    if (
        type(result) is not list
        or len(result) != len(keys)
        or any(type(value) is not bool for value in result)
    ):
        raise RuntimeError("native network returned invalid control outcomes")
    return result


def _lookahead_current(extra_stats):
    if not _dict_keys(extra_stats):
        return None
    rf = extra_stats.get("rigforge")
    if rf is not None and not _dict_keys(rf):
        return None
    ctrl = rf.get("control") if type(rf) is dict else None
    if ctrl is not None and not _dict_keys(ctrl):
        return None
    if type(ctrl) is not dict:
        return _metadata(None, None)
    change_id, status = ctrl.get("change_id"), ctrl.get("status")
    if type(change_id) is str and change_id and not _native_status(status):
        return None
    return _metadata(change_id, status)


def _lookahead_history(extra_stats, limit):
    if type(limit) is not int:
        yield None
        return
    if not _dict_keys(extra_stats):
        yield None
        return
    rf = extra_stats.get("rigforge")
    if not _dict_keys(rf):
        yield None
        return
    history = rf.get("control_history")
    if type(history) is not list:
        yield None
        return
    stop = slice(None, limit).indices(len(history))[1]
    if stop == 0:
        yield None
    for index in range(stop):
        entry = history[index]
        if not _dict_keys(entry):
            yield None
            continue
        change_id, status = entry.get("change_id"), entry.get("status")
        if type(change_id) is str and change_id and not _native_status(status):
            yield None
            continue
        yield _metadata(change_id, status)


class _PollScope:
    def __init__(self, worker_results):
        from mining_dashboard.service import data_audit

        self.caches = {
            "current": OrderedDict(),
            "history": OrderedDict(),
        }
        self.cursors = {
            "current": iter(_lookahead_current(value) for value in worker_results),
            "history": iter(
                metadata
                for value in worker_results
                for metadata in _lookahead_history(value, data_audit._CONTROL_HISTORY_LIMIT)
            ),
        }

    def selected(self, kind, metadata, terminal):
        cache = self.caches[kind]
        key = (*metadata, terminal)
        if key in cache:
            cache.move_to_end(key)
            return cache[key]
        keys = [key]
        seen = {key}
        examined = 0
        cursor = self.cursors[kind]
        while len(keys) < _MAX_ROWS and examined < _MAX_LOOKAHEAD:
            try:
                candidate = next(cursor)
            except StopIteration:
                break
            examined += 1
            if candidate is None:
                continue
            candidate_key = (*candidate, terminal)
            if candidate_key not in seen and candidate_key not in cache:
                keys.append(candidate_key)
                seen.add(candidate_key)
        for candidate, selected in zip(keys, _native(keys, terminal), strict=True):
            cache[candidate] = selected
            cache.move_to_end(candidate)
            while len(cache) > _MAX_CACHE:
                cache.popitem(last=False)
        return cache[key]


def _selected(kind, metadata, terminal):
    scope = _SCOPE.get()
    if scope is None:
        key = (*metadata, terminal)
        selected = _native([key], terminal)[0]
    else:
        selected = scope.selected(kind, metadata, terminal)
    expected = metadata[0] and metadata[1] and metadata[2] == "string" and metadata[3] in terminal
    if selected is not expected:
        raise RuntimeError("native network returned inconsistent control outcome")
    return selected


def _current_compat(reason, payload):
    del reason
    return COMPAT_FUNCTIONS["parse_worker_control_status"](payload)


def parse_worker_control_status(payload):
    from mining_dashboard.client import xmrig_client

    if _REFERENCE_ONLY.get():
        return COMPAT_FUNCTIONS["parse_worker_control_status"](payload)
    if not _dict_keys(payload):
        return _current_compat("payload-shape", payload)
    rf = payload.get("rigforge")
    if isinstance(rf, dict) and not _dict_keys(rf):
        return _current_compat("rigforge-shape", payload)
    ctrl = rf.get("control") if type(rf) is dict else None
    if isinstance(ctrl, dict) and not _dict_keys(ctrl):
        return _current_compat("control-shape", payload)
    if type(ctrl) is not dict:
        metadata = _metadata(None, None)
        _selected("current", metadata, ())
        return None
    change_id, status = ctrl.get("change_id"), ctrl.get("status")
    if type(change_id) is not str and isinstance(change_id, str):
        return _current_compat("change-id-shape", payload)
    if type(change_id) is not str or not change_id:
        metadata = _metadata(change_id, None)
        _selected("current", metadata, ())
        return None
    if type(status) is not str and isinstance(status, str):
        return _current_compat("status-shape", payload)
    if not _native_status(status):
        return _current_compat("status-comparison", payload)
    metadata = _metadata(change_id, status)
    if metadata is None:
        return _current_compat("status-size", payload)
    terminal = _vocabulary(xmrig_client._CONTROL_TERMINAL)
    if terminal is None:
        return _current_compat("terminal-vocabulary", payload)
    reason = ctrl.get("reason")
    if not _selected("current", metadata, terminal):
        return None
    return {"change_id": change_id, "status": status, "reason": reason}


def _entry_compat(reason, entry):
    del reason
    from mining_dashboard.service import data_audit

    return data_audit._terminal_control_entry(entry)


def _history_compat(reason, extra_stats):
    del reason
    yield from COMPAT_FUNCTIONS["_terminal_control_history"](extra_stats)


def _terminal_control_history(extra_stats):
    from mining_dashboard.service import data_audit

    if _REFERENCE_ONLY.get():
        yield from COMPAT_FUNCTIONS["_terminal_control_history"](extra_stats)
        return
    if not _dict_keys(extra_stats):
        yield from _history_compat("payload-shape", extra_stats)
        return
    rf = extra_stats.get("rigforge")
    if isinstance(rf, dict) and not _dict_keys(rf):
        yield from _history_compat("rigforge-shape", extra_stats)
        return
    history = rf.get("control_history") if type(rf) is dict else None
    if isinstance(history, list) and type(history) is not list:
        yield from _history_compat("history-shape", extra_stats)
        return
    limit = data_audit._CONTROL_HISTORY_LIMIT
    if type(limit) is not int:
        yield from _history_compat("history-limit", extra_stats)
        return
    for entry in history[:limit] if type(history) is list else []:
        if data_audit._terminal_control_entry is not PROVIDERS["entry"]:
            if outcome := _entry_compat("entry-provider", entry):
                yield outcome
            continue
        if not isinstance(entry, dict):
            continue
        if type(entry) is not dict:
            if outcome := _entry_compat("entry-shape", entry):
                yield outcome
            continue
        if not _dict_keys(entry):
            if outcome := _entry_compat("entry-keys", entry):
                yield outcome
            continue
        change_id, status = entry.get("change_id"), entry.get("status")
        if type(change_id) is not str and isinstance(change_id, str):
            if outcome := _entry_compat("change-id-shape", entry):
                yield outcome
            continue
        if type(change_id) is not str or not change_id:
            continue
        if type(status) is not str and isinstance(status, str):
            if outcome := _entry_compat("status-shape", entry):
                yield outcome
            continue
        if not _native_status(status):
            if outcome := _entry_compat("status-comparison", entry):
                yield outcome
            continue
        metadata = _metadata(change_id, status)
        if metadata is None:
            if outcome := _entry_compat("status-size", entry):
                yield outcome
            continue
        terminal = _vocabulary(data_audit._CONTROL_TERMINAL)
        if terminal is None:
            if outcome := _entry_compat("terminal-vocabulary", entry):
                yield outcome
            continue
        reason = entry.get("reason")
        if _selected("history", metadata, terminal):
            yield change_id, status, reason


async def _reconcile_compat(reason, self, workers, worker_results):
    del reason
    method = NATIVE_FUNCTIONS["_reconcile_worker_config"]
    token = _REFERENCE_ONLY.set(True)
    try:
        return await method(self, workers, worker_results)
    finally:
        _REFERENCE_ONLY.reset(token)


async def _reconcile_worker_config(self, workers, worker_results):
    from mining_dashboard.service import data_audit

    if type(workers) not in (list, tuple) or type(worker_results) not in (list, tuple):
        return await _reconcile_compat("worker-results-shape", self, workers, worker_results)
    if (
        data_audit.parse_worker_control_status is not parse_worker_control_status
        or data_audit._terminal_control_history is not _terminal_control_history
    ):
        return await _reconcile_compat("selector-provider", self, workers, worker_results)
    token = _SCOPE.set(_PollScope(worker_results[: len(workers)]))
    try:
        return await NATIVE_FUNCTIONS["_reconcile_worker_config"](self, workers, worker_results)
    finally:
        _SCOPE.reset(token)


def install():
    from mining_dashboard.client import xmrig_client
    from mining_dashboard.service import data_audit
    from mining_dashboard.service.workers import worker_refresh

    PROVIDERS.setdefault("entry", data_audit._terminal_control_entry)
    for module, name, native in (
        (xmrig_client, "parse_worker_control_status", parse_worker_control_status),
        (data_audit, "_terminal_control_history", _terminal_control_history),
    ):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(module, name))
        COMPAT_FUNCTIONS.setdefault(name, _clone(getattr(module, name)))
        setattr(module, name, native)
    method = data_audit.DataAuditMixin._reconcile_worker_config
    REFERENCE_FUNCTIONS.setdefault("_reconcile_worker_config", method)
    NATIVE_FUNCTIONS.setdefault("_reconcile_worker_config", _clone(method))
    data_audit.DataAuditMixin._reconcile_worker_config = _reconcile_worker_config
    data_audit.parse_worker_control_status = parse_worker_control_status
    worker_refresh.parse_worker_control_status = parse_worker_control_status
