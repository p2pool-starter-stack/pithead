# ruff: noqa: F403, F405
"""Plain power control route (#2384): POST /api/control/power, modelled on the os-update route."""

from tests.web._server_support import *  # noqa: F403

# The drift guard that pins this route's action set against the host dispatch `case` lives in
# tests/stack/control/test-control-power-verbs.sh, NOT here: the dashboard image's test stage copies
# only dashboard/, so lib/pithead/ does not exist in the container this suite runs in, and a guard
# that reached for it would have to be skipped when absent — which is how a required check quietly
# stops checking. The shell suite has the whole checkout and runs it unconditionally.


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
