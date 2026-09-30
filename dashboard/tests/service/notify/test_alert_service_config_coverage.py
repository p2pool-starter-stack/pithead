# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


def test_every_alert_event_has_a_config_toggle():
    # Every event except the required payout-wallet-down signal has a per-event toggle in
    # config.py TELEGRAM_EVENTS. Payout-wallet-down has no opt-out when alerting is enabled.
    # The config-surface side
    # (config.reference.json, docker-compose.yml, pithead render) is guarded in tests/stack/run.sh.
    evt_values = {v for k, v in vars(AlertService).items() if k.startswith("EVT_")}
    assert AlertService.EVT_PAYOUT_WALLET_DOWN not in TELEGRAM_EVENTS
    assert evt_values - {AlertService.EVT_PAYOUT_WALLET_DOWN} == set(TELEGRAM_EVENTS)
