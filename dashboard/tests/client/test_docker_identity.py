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
