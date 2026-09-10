# ruff: noqa: F403, F405
from tests.web._server_support import *  # noqa: F403


class TestControlRoutesDisabled:
    """With dashboard.control.enabled off (the default) the control routes must not exist at
    all — 404, not 403, so a disabled stack gives no hint the endpoints are there (#33)."""

    async def test_control_routes_absent_when_disabled(self, client):
        assert (await client.get("/api/config")).status == 404
        assert (await client.post("/api/control/preview", json={})).status == 404
        assert (await client.post("/api/control/commit", json={})).status == 404
        assert (await client.post("/api/control/upgrade", json={})).status == 404
        assert (await client.get("/api/control/result?id=x")).status == 404
        assert (await client.post("/api/control/backup")).status == 404
        assert (await client.get("/api/control/backup-download?id=x")).status == 404
        assert (await client.post("/api/control/os-update", json={})).status == 404
        # The config-change audit view is a control-channel artifact — absent with it (#349).
        assert (await client.get("/api/audit")).status == 404
