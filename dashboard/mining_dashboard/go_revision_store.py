from types import FunctionType

from mining_dashboard import go_storage

REFERENCE_FUNCTIONS = {}
COMPAT_FUNCTIONS = {}
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


def _compat(name, reason, *args):
    del reason
    return COMPAT_FUNCTIONS[name](*args)


def _text(value, required=True):
    if type(value) is not str or (required and not value) or len(value) > 4096:
        return False
    if any(0xD800 <= ord(char) <= 0xDFFF for char in value):
        return False
    return len(value.encode("utf-8")) <= 4096


def _cursor(cursor):
    return (
        type(cursor) is go_storage.GoCursor and type(cursor.connection) is go_storage.GoConnection
    )


def _connection(conn):
    return type(conn) is go_storage.GoConnection


def _cid(value):
    return value is None or _text(value, False)


def _number(value):
    return type(value) in (int, float)


def _scalar(value):
    if type(value) is str:
        return _text(value, False)
    return type(value) in (type(None), bool, int, float, bytes)


def _reply_scalar(value):
    return type(value) in (type(None), bool, int, float, str, bytes)


def _result(conn, operation, args):
    return go_storage._decode(conn._request(operation, args=args).get("result"))


def _compat_next(reason, resolve, row, revision, last_change_id):
    del reason
    return resolve(row, revision, last_change_id)


def _row(values, columns):
    return None if values is None else go_storage.GoRow(columns, values)


def prepare(cursor, worker, revision, last_change_id, resolve):
    if not (_cursor(cursor) and _text(worker) and _text(revision) and _cid(last_change_id)):
        return _compat("prepare", "input", cursor, worker, revision, last_change_id, resolve)
    result = _result(
        cursor.connection, "worker-revision-prepare", [worker, revision, last_change_id]
    )
    if type(result) is not dict or set(result) != {"row", "next_slot"}:
        raise RuntimeError("native storage returned invalid revision prepare result")
    values = result["row"]
    if values is not None and (
        type(values) is not list
        or len(values) != 3
        or any(not _reply_scalar(value) for value in values)
    ):
        raise RuntimeError("native storage returned invalid revision prepare row")
    slot = result["next_slot"]
    if slot is not None and (type(slot) is not int or slot not in (0, 2)):
        raise RuntimeError("native storage returned invalid revision prepare result")
    if values is None and slot is not None:
        raise RuntimeError("native storage returned invalid revision prepare result")
    row = _row(values, ("revision", "last_change_id", "drift_from"))
    from mining_dashboard.service.workers import worker_config_store

    provider = worker_config_store.__dict__.get("_next_drift_from")
    if provider is _STATE["next_drift"]:
        drift_from = None if slot is None else row[slot]
    else:
        drift_from = _compat_next("provider", resolve, row, revision, last_change_id)
    return row, drift_from


def write(conn, worker, revision, last_change_id, now, drift_from):
    if not (
        _connection(conn)
        and _text(worker)
        and _text(revision)
        and _cid(last_change_id)
        and _number(now)
        and _scalar(drift_from)
    ):
        return _compat("write", "input", conn, worker, revision, last_change_id, now, drift_from)
    result = _result(
        conn,
        "worker-revision-write",
        [worker, revision, last_change_id, now, drift_from],
    )
    if result is not None:
        raise RuntimeError("native storage returned invalid revision write result")
    return None


def prune(conn, cutoff):
    if not (_connection(conn) and _number(cutoff)):
        return _compat("prune", "input", conn, cutoff)
    result = _result(conn, "worker-revision-prune", [cutoff])
    if result is not None:
        raise RuntimeError("native storage returned invalid revision prune result")
    return None


class _NativeDriftRow:
    __slots__ = ("row", "revision", "visible")

    def __init__(self, row, revision, visible):
        self.row = row
        self.revision = revision
        self.visible = visible

    def __getitem__(self, key):
        return self.row[key]


def drift(cursor, worker, revision):
    if not (_cursor(cursor) and _text(worker) and _text(revision)):
        return _compat("drift", "input", cursor, worker, revision)
    result = _result(cursor.connection, "worker-revision-drift", [worker, revision])
    if (
        type(result) is not dict
        or set(result) != {"row", "visible"}
        or type(result["visible"]) is not bool
    ):
        raise RuntimeError("native storage returned invalid revision drift result")
    values = result["row"]
    if values is not None and (
        type(values) is not list
        or len(values) != 2
        or any(not _reply_scalar(value) for value in values)
    ):
        raise RuntimeError("native storage returned invalid revision drift row")
    if values is None and result["visible"]:
        raise RuntimeError("native storage returned invalid revision drift result")
    row = _row(values, ("revision", "drift_from"))
    return _NativeDriftRow(row, revision, result["visible"])


def visible(row, revision):
    if type(row) is _NativeDriftRow and revision is row.revision:
        return row.visible
    return _compat("visible", "row", row, revision)


def install():
    from mining_dashboard.service.workers import worker_config_store, worker_revision_store

    for name in ("prepare", "write", "prune", "drift", "visible"):
        reference = REFERENCE_FUNCTIONS.setdefault(name, getattr(worker_revision_store, name))
        COMPAT_FUNCTIONS.setdefault(name, _clone(reference))
        setattr(worker_revision_store, name, globals()[name])
    if not _STATE:
        _STATE["next_drift"] = worker_config_store._next_drift_from
