# ruff: noqa: F403, F405
from tests.web._server_support import *  # noqa: F403


class TestControlRoutesEnabled:
    async def test_get_config_masks_secrets(self, control_client):
        resp = await control_client.get("/api/config")
        assert resp.status == 200
        body = await resp.json()
        assert body["dashboard"]["auth"]["password"] == {"__secret__": True}
        # healthchecks.ping_url is a capability secret — masked at the route, never served raw (#33).
        assert body["healthchecks"]["ping_url"] == {"__secret__": True}
        assert "correct horse" not in json.dumps(body)
        assert "SECRET-UUID" not in json.dumps(body)

    async def test_get_config_carries_core_keys_from_the_shared_file(
        self, control_client, control_spool, monkeypatch
    ):
        # #529: the Configuration view's core group reads the SAME config.core-keys.json file the
        # wizard reads (config.HOST_CORE_KEYS_PATH), not a hand-maintained duplicate.
        core_keys_path = control_spool / "config.core-keys.json"
        core_keys_path.write_text(json.dumps(["p2pool.pool", "dashboard.auth.username"]))
        monkeypatch.setattr(control_service.config, "HOST_CORE_KEYS_PATH", str(core_keys_path))
        resp = await control_client.get("/api/config")
        assert resp.status == 200
        body = await resp.json()
        assert body["_core_keys"] == ["p2pool.pool", "dashboard.auth.username"]

    async def test_get_config_degrades_to_no_core_keys_when_file_is_missing(self, control_client):
        # control_spool doesn't write config.core-keys.json, so HOST_CORE_KEYS_PATH points nowhere.
        resp = await control_client.get("/api/config")
        assert resp.status == 200
        body = await resp.json()
        assert body["_core_keys"] == []

    async def test_post_without_control_header_forbidden(self, control_client):
        # The custom header forces a CORS preflight cross-site, which is never granted (CSRF).
        for path in (
            "/api/control/preview",
            "/api/control/commit",
            "/api/control/upgrade",
            "/api/control/backup",
        ):
            resp = await control_client.post(path, json={"config": {}})
            assert resp.status == 403, path

    async def test_preview_submits_request_and_returns_result(
        self, control_client, control_spool, monkeypatch
    ):
        # Pin the request id and pre-write the runner's answer, so wait_result returns at once.
        rid = str(uuid.uuid4())
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
        result = {"status": "previewed", "changes": [], "destructive": False}
        (control_spool / "results" / f"{rid}.json").write_text(json.dumps(result))

        proposed = {
            "p2pool": {"pool": "main"},
            "dashboard": {"auth": {"password": {"__secret__": True}}},
        }
        resp = await control_client.post(
            "/api/control/preview", json={"config": proposed}, headers=CONTROL_HEADERS
        )
        assert resp.status == 200
        body = await resp.json()
        assert body["id"] == rid
        assert body["status"] == "previewed"
        # The spooled request keeps the sentinel (#440): the container never merges live secrets
        # back in — the HOST swaps sentinels for live values when it stages the intent, so the
        # container-readable requests/ spool stays secret-free.
        req = json.loads((control_spool / "requests" / f"{rid}.json").read_text())
        assert req["action"] == "preview"
        assert req["config"]["dashboard"]["auth"]["password"] == {"__secret__": True}
        assert "correct horse" not in json.dumps(req)

    async def test_preview_actor_taken_from_caddy_header(self, control_client, control_spool):
        resp = await control_client.post(
            "/api/control/preview",
            json={"config": {"p2pool": {"pool": "nano"}}},
            headers={**CONTROL_HEADERS, "X-Auth-User": "admin"},
        )
        assert resp.status == 202  # no runner in this test — pending
        rid = (await resp.json())["id"]
        req = json.loads((control_spool / "requests" / f"{rid}.json").read_text())
        assert req["actor"] == "admin"

    async def test_preview_rejects_non_object_config(self, control_client):
        resp = await control_client.post(
            "/api/control/preview", json={"config": "rm -rf /"}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_preview_rejects_non_json_body(self, control_client):
        resp = await control_client.post(
            "/api/control/preview", data=b"not json", headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_commit_requires_valid_intent_id(self, control_client):
        resp = await control_client.post(
            "/api/control/commit", json={"id": "../etc/passwd"}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_commit_waits_past_stale_preview_result(self, control_client, control_spool):
        # The preview result under the same id must not be mistaken for the commit outcome:
        # with only the preview result present, commit times out to 202 pending.
        rid = str(uuid.uuid4())
        (control_spool / "results" / f"{rid}.json").write_text(
            json.dumps({"status": "previewed", "changes": []})
        )
        resp = await control_client.post(
            "/api/control/commit", json={"id": rid}, headers=CONTROL_HEADERS
        )
        assert resp.status == 202
        assert (await resp.json())["status"] == "pending"

    async def test_commit_returns_applied_result(self, control_client, control_spool):
        rid = str(uuid.uuid4())
        (control_spool / "results" / f"{rid}.json").write_text(json.dumps({"status": "applied"}))
        resp = await control_client.post(
            "/api/control/commit", json={"id": rid}, headers=CONTROL_HEADERS
        )
        assert resp.status == 200
        assert (await resp.json())["status"] == "applied"

    async def test_upgrade_submits_typed_intent_and_returns_pending(
        self, control_client, control_spool
    ):
        # 202 straight away: the upgrade recreates this container, so the outcome is polled.
        resp = await control_client.post(
            "/api/control/upgrade",
            json={"version": "v9.9.9"},
            headers={**CONTROL_HEADERS, "X-Auth-User": "admin"},
        )
        assert resp.status == 202
        body = await resp.json()
        assert body["status"] == "pending"
        req = json.loads((control_spool / "requests" / f"{body['id']}.json").read_text())
        # Closed shape: exactly these keys — no config leg, no free-form target for the runner.
        assert req == {
            "id": body["id"],
            "action": "upgrade",
            "actor": "admin",
            "version": "v9.9.9",
        }

    @pytest.mark.parametrize(
        "version",
        ["", "9.9.9", "latest", "v9.9", "v9.9.9; rm -rf /", "v9.9.9\n", 42, None],
    )
    async def test_upgrade_rejects_malformed_version(self, control_client, control_spool, version):
        # Shape-checked before anything touches the spool (the host re-validates regardless).
        resp = await control_client.post(
            "/api/control/upgrade", json={"version": version}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400
        assert list((control_spool / "requests").iterdir()) == []

    async def test_upgrade_rejects_non_json_body(self, control_client):
        resp = await control_client.post(
            "/api/control/upgrade", data=b"not json", headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_result_endpoint_polling(self, control_client, control_spool):
        rid = str(uuid.uuid4())
        resp = await control_client.get(f"/api/control/result?id={rid}")
        assert resp.status == 202
        (control_spool / "results" / f"{rid}.json").write_text(json.dumps({"status": "failed"}))
        resp = await control_client.get(f"/api/control/result?id={rid}")
        assert resp.status == 200
        assert (await resp.json())["status"] == "failed"

    async def test_result_endpoint_rejects_bad_id(self, control_client):
        assert (await control_client.get("/api/control/result?id=..%2Fx")).status == 400

    async def test_preview_spool_failure_is_sanitized(self, control_client, monkeypatch):
        # A broken spool (unwritable requests dir) must come back as a sanitized 500, never a
        # traceback.
        monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", "/nonexistent/requests")
        resp = await control_client.post(
            "/api/control/preview", json={"config": {"p2pool": {}}}, headers=CONTROL_HEADERS
        )
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())

    async def test_upgrade_spool_failure_is_sanitized(self, control_client, monkeypatch):
        # A broken spool (unwritable requests dir) must come back as a sanitized 500.
        monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", "/nonexistent/requests")
        resp = await control_client.post(
            "/api/control/upgrade", json={"version": "v9.9.9"}, headers=CONTROL_HEADERS
        )
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())

    async def test_os_update_submits_typed_intent_and_returns_pending(
        self, control_client, control_spool
    ):
        # 202 straight away: downloads/installs run long and a reboot takes the machine away —
        # the outcome is polled. The action becomes the os-* verb the host runner dispatches on.
        resp = await control_client.post(
            "/api/control/os-update",
            json={"action": "download", "version": "v9.9.9"},
            headers={**CONTROL_HEADERS, "X-Auth-User": "admin"},
        )
        assert resp.status == 202
        body = await resp.json()
        assert body["status"] == "pending"
        req = json.loads((control_spool / "requests" / f"{body['id']}.json").read_text())
        # Closed shape: exactly these keys — no free-form target or path for the runner.
        assert req == {
            "id": body["id"],
            "action": "os-download",
            "actor": "admin",
            "version": "v9.9.9",
        }

    async def test_os_update_actionless_steps_carry_no_version(self, control_client, control_spool):
        resp = await control_client.post(
            "/api/control/os-update", json={"action": "check"}, headers=CONTROL_HEADERS
        )
        assert resp.status == 202
        body = await resp.json()
        req = json.loads((control_spool / "requests" / f"{body['id']}.json").read_text())
        assert req == {"id": body["id"], "action": "os-check", "actor": ""}

    @pytest.mark.parametrize("action", ["", "format-disk", "os-check", "reboot; rm", 42, None])
    async def test_os_update_rejects_unknown_action(self, control_client, control_spool, action):
        # A closed action set, checked before anything touches the spool.
        resp = await control_client.post(
            "/api/control/os-update", json={"action": action}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400
        assert list((control_spool / "requests").iterdir()) == []

    @pytest.mark.parametrize("version", ["9.9.9", "latest", "v9.9.9\n", 42])
    async def test_os_update_rejects_malformed_version(
        self, control_client, control_spool, version
    ):
        resp = await control_client.post(
            "/api/control/os-update",
            json={"action": "download", "version": version},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 400
        assert list((control_spool / "requests").iterdir()) == []

    async def test_os_update_requires_the_control_header(self, control_client):
        resp = await control_client.post("/api/control/os-update", json={"action": "check"})
        assert resp.status == 403

    async def test_os_update_rejects_non_json_body(self, control_client):
        resp = await control_client.post(
            "/api/control/os-update", data=b"not json", headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_os_update_spool_failure_is_sanitized(self, control_client, monkeypatch):
        monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", "/nonexistent/requests")
        resp = await control_client.post(
            "/api/control/os-update", json={"action": "check"}, headers=CONTROL_HEADERS
        )
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())

    async def test_backup_submits_bare_intent_and_returns_pending(
        self, control_client, control_spool
    ):
        # No body, unlike commit/upgrade: the host picks its own passphrase, never the container's.
        resp = await control_client.post(
            "/api/control/backup", headers={**CONTROL_HEADERS, "X-Auth-User": "admin"}
        )
        assert resp.status == 202
        body = await resp.json()
        assert body["status"] == "pending"
        req = json.loads((control_spool / "requests" / f"{body['id']}.json").read_text())
        # Closed shape: exactly these keys — no config leg, no passphrase field to smuggle one in.
        assert req == {"id": body["id"], "action": "backup", "actor": "admin"}

    async def test_backup_spool_failure_is_sanitized(self, control_client, monkeypatch):
        monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", "/nonexistent/requests")
        resp = await control_client.post("/api/control/backup", headers=CONTROL_HEADERS)
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())

    async def test_backup_download_rejects_bad_id(self, control_client):
        resp = await control_client.get("/api/control/backup-download?id=..%2Fx")
        assert resp.status == 400

    async def test_backup_download_404_without_a_result(self, control_client):
        resp = await control_client.get(f"/api/control/backup-download?id={uuid.uuid4()}")
        assert resp.status == 404

    async def test_backup_download_404_when_not_applied(self, control_client, control_spool):
        rid = str(uuid.uuid4())
        (control_spool / "results" / f"{rid}.json").write_text(
            json.dumps({"status": "failed", "error": "boom"})
        )
        resp = await control_client.get(f"/api/control/backup-download?id={rid}")
        assert resp.status == 404

    async def test_backup_download_404_when_archive_missing_on_disk(
        self, control_client, control_spool
    ):
        # The result names an archive but the file itself is gone — 404, not a 500/traceback.
        rid = str(uuid.uuid4())
        (control_spool / "results" / f"{rid}.json").write_text(
            json.dumps({"status": "applied", "archive": "pithead-backup-x.tar.gz.enc"})
        )
        resp = await control_client.get(f"/api/control/backup-download?id={rid}")
        assert resp.status == 404

    async def test_backup_download_streams_the_archive(self, control_client, control_spool):
        rid = str(uuid.uuid4())
        (control_spool / "results" / f"{rid}.json").write_text(
            json.dumps(
                {
                    "status": "applied",
                    "archive": "pithead-backup-20260101-000000.tar.gz.enc",
                    "passphrase": None,  # already redacted; the download must not depend on it
                }
            )
        )
        (control_spool / "results" / f"{rid}.tar.gz.enc").write_bytes(b"ENCRYPTED-ARCHIVE-BYTES")
        resp = await control_client.get(f"/api/control/backup-download?id={rid}")
        assert resp.status == 200
        assert await resp.read() == b"ENCRYPTED-ARCHIVE-BYTES"
        assert (
            'filename="pithead-backup-20260101-000000.tar.gz.enc"'
            in resp.headers["Content-Disposition"]
        )

    async def test_config_read_failure_is_sanitized(self, control_client, monkeypatch):
        monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", "/nonexistent/config.json")
        resp = await control_client.get("/api/config")
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())
