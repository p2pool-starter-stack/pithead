import pytest
import requests
from test_contract import FakeWorkerApi, _probe_worker, parse_rigforge


@pytest.mark.parametrize("fake_mode", ["none", "name", "token"])
@pytest.mark.parametrize("client_mode", ["none", "name", "token"])
def test_worker_auth_mode_grid(fake_mode, client_mode):
    with FakeWorkerApi(auth=fake_mode, name="rig1", token="fleetwide") as fake:
        result = _probe_worker(fake, auth=client_mode, fleet_token="fleetwide")
    expected = fake_mode == "none" or fake_mode == client_mode
    assert result["api_ok"] is expected
    assert result["adopted"] is False
    if expected:
        assert parse_rigforge(result)["version"] == "1.16.0"
    else:
        assert result == {"api_ok": False, "adopted": False}


@pytest.mark.parametrize("mode", ["name", "token"])
@pytest.mark.parametrize("credential,code", [(None, 401), ("wrong", 403), ("rig1", 200)])
def test_worker_auth_wire_status(mode, credential, code):
    with FakeWorkerApi(auth=mode, name="rig1", token="rig1") as fake:
        headers = {} if credential is None else {"Authorization": f"Bearer {credential}"}
        response = requests.get(
            f"http://{fake.host}:{fake.port}/1/summary", headers=headers, timeout=5
        )
    assert response.status_code == code
    if code != 200:
        assert "rig1" not in response.text


@pytest.mark.parametrize("token,expected", [("", False), ("wrong", False), ("fleetwide", True)])
def test_worker_token_missing_wrong_and_matching(token, expected):
    with FakeWorkerApi(auth="token", token="fleetwide") as fake:
        result = _probe_worker(fake, auth="token", fleet_token=token)
    assert result["api_ok"] is expected
    assert result["adopted"] is False
