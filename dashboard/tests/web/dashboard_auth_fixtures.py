import base64
import json
import secrets

import bcrypt
import pytest

from mining_dashboard.web import server


@pytest.fixture
def auth_config(tmp_path, monkeypatch):
    password = secrets.token_urlsafe(18)
    machine = secrets.token_urlsafe(18)
    hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=4)).decode()
    path = tmp_path / "auth.json"
    data = {
        "users": [
            {"name": "owner", "role": "admin", "password_hash": hashed},
            {"name": "observer", "role": "viewer", "password_hash": hashed},
        ],
        "metrics_password_hash": bcrypt.hashpw(machine.encode(), bcrypt.gensalt(rounds=4)).decode(),
    }
    path.write_text(json.dumps(data))
    monkeypatch.setenv("DASHBOARD_AUTH_FILE", str(path))
    monkeypatch.setattr(server.config, "DASHBOARD_CONTROL_ENABLED", True)
    return path, data, password, machine


@pytest.fixture
async def auth_client(auth_config, state_manager, aiohttp_client):
    return await aiohttp_client(server.create_app(state_manager, {}))


def origin(client):
    return str(client.make_url("/").origin())


async def login(client, password, name="owner", **kwargs):
    return await client.post(
        "/login",
        data={"username": name, "password": password},
        headers={"Origin": origin(client), **kwargs},
        allow_redirects=False,
    )


def basic(name, password):
    return "Basic " + base64.b64encode(f"{name}:{password}".encode()).decode()
