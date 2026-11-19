# ruff: noqa: F403, F405
from mining_dashboard.service.notify.alert_levels import ALL_EVENTS, ALWAYS_ON_EVENTS
from tests.service.notify._alert_service_support import *  # noqa: F403


def test_every_alert_event_has_a_level():
    evt_values = {v for k, v in vars(AlertService).items() if k.startswith("EVT_")}
    assert evt_values == ALL_EVENTS | ALWAYS_ON_EVENTS
