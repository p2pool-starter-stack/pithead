# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


def test_every_alert_event_has_a_config_toggle():
    # The canonical event set (AlertService.EVT_*) must line up 1:1 with the per-event toggles in
    # config.py TELEGRAM_EVENTS — so adding an alert but forgetting its toggle (or vice versa) fails
    # here instead of silently shipping an un-toggleable / dead event. The config-surface side
    # (config.reference.json, docker-compose.yml, pithead render) is guarded in tests/stack/run.sh.
    evt_values = {v for k, v in vars(AlertService).items() if k.startswith("EVT_")}
    assert evt_values == set(TELEGRAM_EVENTS)
