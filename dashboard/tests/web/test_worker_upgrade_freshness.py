import json
from unittest.mock import MagicMock

from mining_dashboard.web import server


class _Request:
    headers = {server.CONTROL_HEADER: "1"}
    app = {
        "latest_data": {
            "workers": [
                {
                    "name": "rig",
                    "rigforge": {
                        "version": "1.2.3",
                        "generated_at": "2020-01-01T00:00:00Z",
                        "stale": False,
                    },
                }
            ]
        },
        "state_manager": MagicMock(),
        "_bg_tasks": set(),
    }

    async def json(self):
        return {"worker": "rig", "version": "v1.2.3"}


class _Task:
    def add_done_callback(self, callback):
        return None


async def test_stale_version_cannot_short_circuit_worker_upgrade(monkeypatch):
    submitted = []
    monkeypatch.setattr(
        server.control_service,
        "submit_worker_upgrade",
        lambda worker, version, actor, appliance=False: (
            submitted.append((worker, version)) or "request-id"
        ),
    )

    def fake_task(coro):
        coro.close()
        return _Task()

    monkeypatch.setattr(server.asyncio, "create_task", fake_task)
    response = await server.handle_worker_upgrade(_Request())
    assert response.status == 202
    assert json.loads(response.text)["status"] == "pending"
    assert submitted == [("rig", "v1.2.3")]
