import json

from mining_dashboard import go_channel
from mining_dashboard.client import rigforge_freshness

REFERENCE_FUNCTIONS = {}
REFERENCE_FEED_AGE = rigforge_freshness.feed_age


def _row(worker, report):
    stamp = report.get("generated_at") if isinstance(report, dict) else None
    kind = "dict" if isinstance(report, dict) else "falsy" if not report else type(report).__name__
    return [worker.get("name"), worker.get("ip"), kind, stamp if isinstance(stamp, str) else None]


def _preserve_with_age_provider(current_workers, next_workers, feed_age):
    current = {
        (worker.get("name"), worker.get("ip")): worker.get("rigforge") for worker in current_workers
    }
    for worker in next_workers:
        old = current.get((worker.get("name"), worker.get("ip")))
        if not isinstance(old, dict) or feed_age(old.get("generated_at")) is None:
            continue
        new = worker.get("rigforge") or {}
        if feed_age(new.get("generated_at")) is None or old["generated_at"] >= new["generated_at"]:
            worker["rigforge"] = old


def preserve_newer_reports(current_workers, next_workers):
    from mining_dashboard.service.workers import worker_refresh

    if worker_refresh.feed_age is not REFERENCE_FEED_AGE:
        return _preserve_with_age_provider(current_workers, next_workers, worker_refresh.feed_age)
    current_workers, next_workers = list(current_workers), list(next_workers)
    current_reports = [worker.get("rigforge") for worker in current_workers]
    current_rows, next_rows = (
        [
            _row(worker, report)
            for worker, report in zip(current_workers, current_reports, strict=True)
        ],
        [_row(worker, worker.get("rigforge")) for worker in next_workers],
    )
    reply = go_channel.call(
        "fleet",
        {
            "operation": "poll_preserve_reports",
            "args": [current_rows, next_rows, rigforge_freshness.time.time()],
            "envelope": True,
        },
    )
    if not isinstance(reply, dict) or set(reply) != {"replacements", "error"}:
        raise RuntimeError("native report preservation returned invalid plan")
    replacements, error = reply["replacements"], reply["error"]
    if not isinstance(replacements, list) or any(
        not isinstance(pair, list)
        or len(pair) != 2
        or any(type(index) is not int for index in pair)
        or not 0 <= pair[0] < len(next_workers)
        or not 0 <= pair[1] < len(current_workers)
        or current_rows[pair[1]][:2] != next_rows[pair[0]][:2]
        or not isinstance(current_reports[pair[1]], dict)
        for pair in replacements
    ):
        raise RuntimeError("native report preservation returned invalid replacements")
    indices = [pair[0] for pair in replacements]
    if (
        indices != sorted(set(indices))
        or error is not None
        and (
            not isinstance(error, dict)
            or set(error) != {"kind", "message"}
            or error["kind"] not in ("AttributeError", "TypeError", "OverflowError")
            or not isinstance(error["message"], str)
        )
    ):
        raise RuntimeError("native report preservation returned invalid result")
    for next_index, current_index in replacements:
        next_workers[next_index]["rigforge"] = current_reports[current_index]
    if error is not None:
        go_channel.response("fleet", json.dumps({"ok": False, "error": error}))


def install():
    from mining_dashboard.service.workers import worker_refresh

    REFERENCE_FUNCTIONS.setdefault("preserve_newer_reports", worker_refresh.preserve_newer_reports)
    worker_refresh.preserve_newer_reports = preserve_newer_reports
