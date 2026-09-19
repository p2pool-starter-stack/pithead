# ruff: noqa: F403, F405
"""Plain power control route (#2384): POST /api/control/power, modelled on the os-update route."""

from pathlib import Path

from tests.web._server_support import *  # noqa: F403

# The shell case this route's actions must match exactly (49-control-request-loop.sh) — a verb
# added on one side and not the other must go red here, not silently 400 or be refused host-side.
_DISPATCH_LOOP = (
    Path(__file__).resolve().parents[3] / "lib" / "pithead" / "49-control-request-loop.sh"
).read_text()


class TestControlPowerRoute:
    async def test_reboot_submits_typed_intent_and_returns_pending(
        self, control_client, control_spool
    ):
        resp = await control_client.post(
            "/api/control/power",
            json={"action": "reboot"},
            headers={**CONTROL_HEADERS, "X-Auth-User": "admin"},
        )
        assert resp.status == 202
        body = await resp.json()
        assert body["status"] == "pending"
        req = json.loads((control_spool / "requests" / f"{body['id']}.json").read_text())
        # Closed shape: exactly these keys — no free-form target for the host runner.
        assert req == {"id": body["id"], "action": "sys-reboot", "actor": "admin"}

    async def test_poweroff_submits_typed_intent(self, control_client, control_spool):
        resp = await control_client.post(
            "/api/control/power", json={"action": "poweroff"}, headers=CONTROL_HEADERS
        )
        assert resp.status == 202
        body = await resp.json()
        req = json.loads((control_spool / "requests" / f"{body['id']}.json").read_text())
        assert req == {"id": body["id"], "action": "sys-poweroff", "actor": ""}

    @pytest.mark.parametrize("action", ["", "os-reboot", "format-disk", "reboot; rm", 42, None])
    async def test_rejects_unknown_action_before_the_spool(
        self, control_client, control_spool, action
    ):
        resp = await control_client.post(
            "/api/control/power", json={"action": action}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400
        assert list((control_spool / "requests").iterdir()) == []

    async def test_requires_the_control_header(self, control_client):
        resp = await control_client.post("/api/control/power", json={"action": "reboot"})
        assert resp.status == 403

    async def test_rejects_non_json_body(self, control_client):
        resp = await control_client.post(
            "/api/control/power", data=b"not json", headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_spool_failure_is_sanitized(self, control_client, monkeypatch):
        monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", "/nonexistent/requests")
        resp = await control_client.post(
            "/api/control/power", json={"action": "reboot"}, headers=CONTROL_HEADERS
        )
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())

    def test_action_set_matches_the_host_dispatch_case(self):
        from mining_dashboard.web.views.power_views import POWER_ACTIONS

        for action in POWER_ACTIONS:
            assert f"sys-{action})" in _DISPATCH_LOOP, (
                f"POWER_ACTIONS has {action!r} but 49-control-request-loop.sh has no "
                f"sys-{action} case — a verb added on one side only"
            )
