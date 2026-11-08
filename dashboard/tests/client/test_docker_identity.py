import json
from unittest.mock import MagicMock, patch

import pytest

from mining_dashboard.client.docker.docker_control import DockerControl
from tests.client.test_docker_control import _AsyncCM, _FakeResp


@pytest.mark.parametrize(
    "body,status,expected",
    [
        (json.dumps({"Id": "a" * 64, "Env": ["private=value"]}), 200, "a" * 64),
        (json.dumps({"Id": "private.onion"}), 200, "unavailable"),
        (json.dumps({"Id": 42}), 200, "unavailable"),
        ("[]", 200, "unavailable"),
        ("invalid", 200, "unavailable"),
        ("x" * 65537, 200, "unavailable"),
        ("", 404, "unavailable"),
    ],
)
async def test_identity_is_bounded_opaque_and_read_only(body, status, expected):
    session = MagicMock()
    session.get.return_value = _AsyncCM(_FakeResp(status, body))
    with patch(
        "mining_dashboard.client.docker.docker_control.aiohttp.ClientSession",
        return_value=_AsyncCM(session),
    ):
        assert await DockerControl().identity("tor") == expected
    assert session.get.call_args.kwargs == {"timeout": 1}
    assert session.get.call_args.args[0].endswith("/containers/tor/json")
    session.post.assert_not_called()


async def test_identity_failure_is_unavailable():
    with patch(
        "mining_dashboard.client.docker.docker_control.aiohttp.ClientSession",
        side_effect=OSError("private"),
    ):
        assert await DockerControl().identity("tor") == "unavailable"


@pytest.mark.parametrize("failure", ["identity", "observer"])
async def test_receipt_metadata_failure_preserves_mutation(failure, tmp_path):
    lock_file = tmp_path / "mutation.lock"
    lock_file.touch()
    control = DockerControl(lock_file=lock_file)
    session = MagicMock()
    session.get.return_value = _AsyncCM(_FakeResp(200, json.dumps({"Id": "a" * 64})))
    session.post.return_value = _AsyncCM(_FakeResp(204))
    if failure == "identity":
        session.get.side_effect = OSError("private")

    def observed(identity):
        assert identity == ("unavailable" if failure == "identity" else "a" * 64)
        if failure == "observer":
            raise ValueError("private")

    with patch(
        "mining_dashboard.client.docker.docker_control.aiohttp.ClientSession",
        return_value=_AsyncCM(session),
    ):
        assert await control.start("tor", on_identity=observed) is True
    session.post.assert_called_once()
