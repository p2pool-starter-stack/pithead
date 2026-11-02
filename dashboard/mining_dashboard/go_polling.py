import asyncio

from mining_dashboard import go_channel

REFERENCE_FUNCTIONS = {}
HELPERS = (
    "_parse_proxy_list_worker",
    "_parse_legacy_dict_worker",
    "_normalize_proxy_workers",
    "_parse_proxy_summary",
    "_merge_proxy_summary",
    "_merge_direct_stats",
    "_aggregate_hashrate",
    "_aggregate_window_hashrates",
    "_summary_deltas",
    "_shares_to_record",
)


def _run(operation, args, *, now=None):
    return go_channel.call(
        "fleet",
        {"operation": "poll_" + operation, "args": args, "now": now or 0, "envelope": True},
    )


def _clock(now):
    from mining_dashboard.service import data_helpers

    return data_helpers.datetime.now(data_helpers.UTC).timestamp() if now is None else now


def _parse_proxy_list_worker(row, now=None):
    from mining_dashboard.service import data_helpers

    return _run(
        "parse_proxy_list_worker",
        [row, data_helpers.config.WORKER_OFFLINE_AFTER_SEC],
        now=_clock(now),
    )


def _parse_legacy_dict_worker(row):
    return _run("parse_legacy_dict_worker", [row])


def _normalize_proxy_workers(payload, now=None):
    from mining_dashboard.service import data_helpers

    return _run(
        "normalize_proxy_workers",
        [payload, data_helpers.config.WORKER_OFFLINE_AFTER_SEC],
        now=_clock(now),
    )


def _parse_proxy_summary(payload):
    return _run("parse_proxy_summary", [payload])


def _merge_proxy_summary(last_good, payload):
    reply = _run("merge_proxy_summary", [last_good, payload])
    if (
        not isinstance(reply, dict)
        or set(reply) != {"adopt", "summary"}
        or type(reply["adopt"]) is not bool
        or (reply["adopt"] and not isinstance(reply["summary"], dict))
    ):
        raise RuntimeError("native proxy summary returned invalid data")
    return reply["summary"] if reply["adopt"] else last_good


def _patches(reply, count, keys):
    if (
        not isinstance(reply, list)
        or len(reply) != count
        or any(not isinstance(row, dict) or not set(row).issubset(keys) for row in reply)
    ):
        raise RuntimeError("native worker poll returned invalid patches")
    return reply


def _merge_direct_stats(workers, results, active_pool_port):
    from mining_dashboard import go_rigforge
    from mining_dashboard.service import data_helpers

    workers, results = list(workers), list(results)
    count = min(len(workers), len(results))
    if data_helpers.parse_rigforge is go_rigforge.parse_rigforge:
        from mining_dashboard.client import rigforge_freshness

        operation = "merge_rigforge_stats"
        rigforge = [rigforge_freshness.time.time() if row else None for row in results[:count]]
    else:
        operation = "merge_direct_stats"
        rigforge = [data_helpers.parse_rigforge(row) if row else None for row in results[:count]]
    patches = _patches(
        _run(operation, [workers, results, active_pool_port, rigforge]),
        count,
        {"api_ok", "adopted", "rigforge", "uptime", "h10", "h60", "h15", "active_pool"},
    )
    for worker, patch in zip(workers, patches, strict=False):
        worker.update(patch)
    return workers[:count]


def _aggregate_hashrate(workers):
    return tuple(_run("aggregate_hashrate", [list(workers)]))


def _aggregate_window_hashrates(workers):
    return _run("aggregate_window_hashrates", [list(workers)])


def _summary_deltas(last_totals, current_totals):
    delta, _baseline = _run("summary_deltas", [last_totals, current_totals])
    return delta, current_totals


def _shares_to_record(last_known_total, current_total):
    return tuple(_run("shares_to_record", [last_known_total, current_total]))


def lifecycle_update(self, workers, now):
    workers = list(workers)
    reply = _run("lifecycle", [workers, list(self._state.items()), self.falloff_sec], now=now)
    if not isinstance(reply, dict) or set(reply) != {"patches", "live_indices", "state"}:
        raise RuntimeError("native worker lifecycle returned invalid data")
    patches = _patches(reply["patches"], len(workers), {"uptime"})
    indices, records = reply["live_indices"], reply["state"]
    if (
        not isinstance(indices, list)
        or any(type(index) is not int or not 0 <= index < len(workers) for index in indices)
        or indices != sorted(set(indices))
        or not isinstance(records, list)
    ):
        raise RuntimeError("native worker lifecycle returned invalid state")
    state = {}
    for record in records:
        if (
            not isinstance(record, list)
            or len(record) != 2
            or (record[0] is not None and not isinstance(record[0], str))
            or not isinstance(record[1], dict)
            or set(record[1]) != {"connected_since", "last_active"}
            or record[0] in state
        ):
            raise RuntimeError("native worker lifecycle returned invalid record")
        name, values = record
        current = self._state.get(name)
        state[name] = current if current is not None else {}
    for record in records:
        state[record[0]].update(record[1])
    for worker, patch in zip(workers, patches, strict=True):
        worker.update(patch)
    self._state = state
    return [workers[index] for index in indices]


async def probe(self, client, workers):
    workers = [
        {"name": worker["name"], "ip": worker["ip"], "status": worker.get("status")}
        for worker in workers
    ]
    wanted = await asyncio.to_thread(_run, "probe_plan", [workers, list(self._answered)])
    if (
        not isinstance(wanted, list)
        or len(wanted) != len(workers)
        or any(type(value) is not bool for value in wanted)
    ):
        raise RuntimeError("native worker probe returned invalid plan")
    probes = [
        client.get_stats(worker["ip"], worker["name"])
        for worker, selected in zip(workers, wanted, strict=True)
        if selected
    ]
    probed = await asyncio.gather(*probes)
    reply = await asyncio.to_thread(_run, "probe_complete", [workers, wanted, probed])
    if not isinstance(reply, dict) or set(reply) != {"result_indices", "answered"}:
        raise RuntimeError("native worker probe returned invalid result")
    indices, answered = reply["result_indices"], reply["answered"]
    if (
        not isinstance(indices, list)
        or len(indices) != len(workers)
        or any(
            index is not None and (type(index) is not int or not 0 <= index < len(probed))
            for index in indices
        )
        or [index is not None for index in indices] != wanted
        or [index for index in indices if index is not None] != list(range(len(probed)))
        or not isinstance(answered, list)
        or any(
            not isinstance(pair, list)
            or len(pair) != 2
            or any(value is not None and not isinstance(value, str) for value in pair)
            for pair in answered
        )
    ):
        raise RuntimeError("native worker probe returned invalid alignment")
    self._answered = {tuple(pair) for pair in answered}
    return [{} if index is None else probed[index] for index in indices]


def install():
    from mining_dashboard.service import data_helpers, data_service, worker_probe

    for name in HELPERS:
        REFERENCE_FUNCTIONS.setdefault(name, getattr(data_helpers, name))
        setattr(data_helpers, name, globals()[name])
        if hasattr(data_service, name):
            setattr(data_service, name, globals()[name])
    REFERENCE_FUNCTIONS.setdefault("WorkerLifecycle.update", data_helpers.WorkerLifecycle.update)
    REFERENCE_FUNCTIONS.setdefault("WorkerProber.probe", worker_probe.WorkerProber.probe)
    data_helpers.WorkerLifecycle.update = lifecycle_update
    worker_probe.WorkerProber.probe = probe
