from unittest.mock import AsyncMock, PropertyMock, patch

import pytest

from tests.service._data_service_support import _make_service, ds_mod
from tests.service.test_data_service_aggregation_and_sync import TestRunIteration as _Iteration


@pytest.mark.parametrize(
    "reading",
    [None, {"running": False, "health": "unhealthy"}, {"running": True, "health": "healthy"}],
)
async def test_overview_reuses_the_existing_container_health_snapshot(reading):
    service, _, _ = _make_service()
    containers = {"tor": reading} if reading is not None else {}
    with (
        patch.object(
            type(service.alert_service), "enabled", new_callable=PropertyMock, return_value=False
        ),
        patch.object(ds_mod, "DASHBOARD_FAIL_CLOSED", True),
        patch.object(ds_mod, "get_container_health", AsyncMock(return_value=containers)) as collect,
    ):
        await _Iteration()._run_one_iteration(service, {"is_syncing": False}, {"is_syncing": False})
    assert service.latest_data["tor_health"] == reading
    collect.assert_awaited_once()
