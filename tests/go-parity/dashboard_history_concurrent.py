import asyncio
import json
from collections import deque

import pytest
from aiohttp import ClientSession, ClientTimeout, web
from aiohttp.test_utils import TestServer
from dashboard_http_plugin import DashboardProcess, reference_create_app

from mining_dashboard import go_bridge
from mining_dashboard.config import config
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web import server
from mining_dashboard.web.views import charts


def require(condition, message):
    if not condition:
        raise AssertionError(message)


@pytest.mark.asyncio
@pytest.mark.parametrize("clients", [4, 12])
async def test_large_history_concurrent_state(monkeypatch, clients):
    now = 3_000_000.0
    monkeypatch.setattr(charts.time, "time", lambda: now)
    monkeypatch.setattr(config, "PAYOUT_CONFIRM_ENABLED", False)
    monkeypatch.setattr(config, "TARI_PAYOUT_CONFIRM_ENABLED", False)
    history = [
        {
            "t": str(index),
            "timestamp": now - (86_399 - index) * 30,
            "v": float(index % 100 + 2),
            "v_p2pool": float(index % 100),
            "v_xvb": 2.0,
        }
        for index in range(86_400)
    ]
    manager = StateManager(db_path=":memory:")
    manager.state["hashrate_history"] = deque(history)
    data = {"shares": [], "workers": [], "timestamp": now, "total_live_h15": 50.0}
    expected = server.build_state(data, manager, "all")
    expected = json.loads(json.dumps(expected))
    requests = {"GET": [], "POST": []}
    ready = asyncio.Event()
    release = asyncio.Event()

    @web.middleware
    async def record(request, handler):
        require(request.path != "/api/state", "Python state fallback used for compact inputs")
        if request.path != "/_go/state":
            return await handler(request)
        if request.method == "GET":
            ready.set()
            await release.wait()
        else:
            requests["POST"].append(request.content_length or 0)
        response = await handler(request)
        envelope = json.loads(response.body)
        if request.method == "GET":
            require("history" not in envelope["input"]["domain"], "GET carried raw history")
            require(
                len(envelope["input"]["chart"]["history"]) <= 700,
                "GET carried unbounded chart rows",
            )
            requests["GET"].append(len(response.body))
        else:
            require("history" not in envelope["input"]["chart"], "POST returned raw history")
        require(len(response.body) < 1 << 20, "private state envelope exceeds 1 MiB")
        return response

    app = reference_create_app(manager, data)
    app.middlewares.append(record)
    go_bridge.install(app)
    reference = TestServer(app)
    process = None
    try:
        await reference.start_server()
        process = DashboardProcess(str(reference.make_url("/")), False)
        await process.start()
        async with ClientSession(timeout=ClientTimeout(total=15)) as session:

            async def state():
                async with session.get(f"{process.url}/api/state?range=all") as response:
                    require(response.status == 200, "concurrent state request failed")
                    return await response.json()

            tasks = [asyncio.create_task(state()) for _ in range(clients)]
            await asyncio.wait_for(ready.wait(), timeout=5)
            await asyncio.sleep(0.05)
            release.set()
            results = await asyncio.gather(*tasks)
            require(all(result == expected for result in results), "state differs from reference")
            require(len(requests["GET"]) == 1, "concurrent polls collected multiple snapshots")
            require(len(requests["POST"]) == 1, "concurrent polls completed multiple snapshots")
            require(max(requests["POST"]) < 1 << 20, "POST input exceeds 1 MiB")
    finally:
        release.set()
        if process is not None:
            await process.close()
        await reference.close()
        manager.close()
