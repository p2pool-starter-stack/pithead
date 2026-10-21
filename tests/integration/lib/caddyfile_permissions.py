import json
import secrets
import stat
import subprocess
import time
from pathlib import Path

from access_log_retention import Caddy, require


def wait_result(client, intent, logins, exclude=None):
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        for login in logins:
            client.good = login
            try:
                code, body = client.request("/api/control/result?id=" + intent)
            except (RuntimeError, subprocess.TimeoutExpired):
                continue
            if code not in (200, 202):
                continue
            result = json.loads(body)
            if result.get("status") not in ("pending", exclude):
                return result
        time.sleep(3)
    raise RuntimeError("GUI credential rotation did not settle within 240 seconds")


def main():
    client = Caddy()
    old_login = client.good
    code, body = client.request("/api/config")
    require(code == 200, "authenticated GUI configuration must load")
    proposed = json.loads(body)
    password = secrets.token_urlsafe(24)
    proposed["dashboard"]["auth"]["password"] = password
    new_login = proposed["dashboard"]["auth"]["username"] + ":" + password
    code, body = client.request("/api/control/preview", payload={"config": proposed})
    require(code in (200, 202), "GUI password preview must be accepted")
    preview = json.loads(body)
    intent = preview["id"]
    if preview.get("status") == "pending":
        preview = wait_result(client, intent, [old_login])
    require(preview.get("status") == "previewed", "GUI password preview must succeed")
    commit = {"id": intent}
    if preview.get("destructive"):
        commit["confirm"] = "APPLY"
    if preview.get("approval_required"):
        commit.update(approve=True, payout_suffixes={})
    Path("Caddyfile").chmod(0o664)
    try:
        code, _ = client.request("/api/control/commit", payload=commit)
        require(code in (200, 202, 502, 503, 504), "GUI password commit must be accepted")
    except subprocess.TimeoutExpired:
        pass
    except RuntimeError as exc:
        if str(exc) != "Caddy transport failed":
            raise
    result = wait_result(client, intent, [new_login, old_login], exclude="previewed")
    require(result.get("status") == "applied", "GUI password commit must apply")
    require(
        stat.S_IMODE(Path("Caddyfile").stat().st_mode) == 0o644,
        "GUI credential rotation must normalize Caddyfile to 0644",
    )
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        try:
            client.good = new_login
            new_code, _ = client.request("/api/config")
            client.good = old_login
            old_code, _ = client.request("/api/config")
            if new_code == 200 and old_code == 401:
                print("caddyfile-permissions: complete")
                return
        except (RuntimeError, subprocess.TimeoutExpired):
            pass
        time.sleep(3)
    raise RuntimeError("Caddy must accept the new GUI password and reject the old password")


if __name__ == "__main__":
    main()
