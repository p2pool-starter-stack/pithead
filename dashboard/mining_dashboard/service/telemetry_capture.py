import asyncio

DISK_FIELDS = ("monero_db_bytes", "disk_used_gb", "disk_total_gb")
NETWORK_FIELDS = ("difficulty", "height", "reward", "pool_hashrate")
WORKER_FIELDS = ("ts", "name", "h15", "accepted", "rejected")


def plan(self, phase, args):
    if phase == "hourly":
        now, last, interval, monero, disk = args
        due = now - last >= interval
        return {
            "due": due,
            "values": [
                monero.get("db_size", 0) or 0,
                (disk or {}).get("used_gb", 0) or 0,
                (disk or {}).get("total_gb", 0) or 0,
            ]
            if due
            else [],
        }
    if phase == "network":
        network, pool = args
        return [
            network.get("difficulty", 0) or 0,
            network.get("height", 0) or 0,
            network.get("reward", 0) or 0,
            pool.get("hashrate", 0) or 0,
        ]
    if phase == "worker_due":
        now, last, interval = args
        return now - last >= interval
    if phase == "workers":
        now, last, interval, workers = args
        due = now - last >= interval
        return {
            "due": due,
            "rows": [
                [
                    now,
                    worker.get("name", ""),
                    worker.get("h15", 0) or 0,
                    worker.get("accepted", 0) or 0,
                    worker.get("rejected", 0) or 0,
                ]
                for worker in workers
                if worker.get("status") == "online"
            ]
            if due
            else [],
        }
    raise ValueError("unsupported telemetry phase")


def _project(value, keys):
    return {key: value[key] for key in keys if key in value} if isinstance(value, dict) else value


def _validate(plan, field, width):
    if (
        not isinstance(plan, dict)
        or set(plan) != {"due", field}
        or type(plan["due"]) is not bool
        or not isinstance(plan[field], list)
        or (not plan["due"] and plan[field])
        or (field == "values" and plan["due"] and len(plan[field]) != width)
        or (
            field == "rows"
            and any(not isinstance(row, list) or len(row) != width for row in plan[field])
        )
    ):
        raise RuntimeError("native telemetry returned invalid plan")
    return plan


async def capture(self, now, monero_sync, disk_usage, network_stats, pool_local, workers):
    from mining_dashboard.service import data_service

    hourly = _validate(
        self._telemetry_plan(
            "hourly",
            [
                now,
                self._last_hourly_capture,
                data_service._HOURLY_CAPTURE_SEC,
                _project(monero_sync, ("db_size",)),
                _project(disk_usage, ("used_gb", "total_gb")),
            ],
        ),
        "values",
        3,
    )
    if hourly["due"]:
        await asyncio.to_thread(
            self.state_manager.add_disk_growth,
            now,
            **dict(zip(DISK_FIELDS, hourly["values"], strict=True)),
        )
        network = self._telemetry_plan(
            "network",
            [
                _project(network_stats, ("difficulty", "height", "reward")),
                _project(pool_local, ("hashrate",)),
            ],
        )
        if not isinstance(network, list) or len(network) != 4:
            raise RuntimeError("native telemetry returned invalid network values")
        await asyncio.to_thread(
            self.state_manager.add_network_history,
            now,
            **dict(zip(NETWORK_FIELDS, network, strict=True)),
        )
        self._last_hourly_capture = now
    worker_clock = [now, self._last_worker_capture, data_service._WORKER_HISTORY_CAPTURE_SEC]
    worker_due = self._telemetry_plan("worker_due", worker_clock)
    if type(worker_due) is not bool:
        raise RuntimeError("native telemetry returned invalid worker gate")
    if not worker_due:
        return
    worker_plan = _validate(
        self._telemetry_plan(
            "workers",
            [
                *worker_clock,
                [
                    _project(worker, ("status", "name", "h15", "accepted", "rejected"))
                    for worker in workers
                ],
            ],
        ),
        "rows",
        5,
    )
    if not worker_plan["due"]:
        raise RuntimeError("native telemetry returned invalid worker gate")
    rows = worker_plan["rows"]
    if len(rows) > len(workers) or any(row[0] != now for row in rows):
        raise RuntimeError("native telemetry returned invalid worker values")
    if rows:
        await asyncio.to_thread(
            self.state_manager.add_worker_history,
            [dict(zip(WORKER_FIELDS, row, strict=True)) for row in rows],
        )
    self._last_worker_capture = now
