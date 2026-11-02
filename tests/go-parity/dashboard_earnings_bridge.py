import pytest

from mining_dashboard import go_bridge

# ruff: noqa: S101


class Request:
    def __init__(self, prepared):
        self.prepared = prepared
        self.query = {}

    def clone(self, **_kwargs):
        return self

    async def json(self):
        return self.prepared


@pytest.mark.asyncio
@pytest.mark.parametrize("marker", [None, False, 1, "true"])
async def test_invalid_native_marker_is_fatal(marker):
    prepared = {"snapshot": {"storage": {}, "settings": {}}, "earnings": marker}
    with pytest.raises(RuntimeError, match="invalid native earnings marker"):
        await go_bridge._finish_state(Request(prepared))


@pytest.mark.asyncio
async def test_claimed_native_earnings_cannot_omit_prepared_result():
    prepared = {
        "snapshot": {"storage": {}, "settings": {}},
        "earnings": True,
        "sections": {},
    }
    with pytest.raises(KeyError, match="build_earnings"):
        await go_bridge._finish_state(Request(prepared))
