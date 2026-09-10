# ruff: noqa: F401
from types import SimpleNamespace

import mining_dashboard.service.notify.alert_service as alert_mod
from mining_dashboard.config.config import TELEGRAM_EVENTS
from mining_dashboard.service.notify.alert_service import AlertService
from mining_dashboard.service.workers.worker_presence import WorkerPresenceMonitor


class _FakeNotifier:
    """Stand-in transport: records sends, lets tests gate which events are 'enabled'."""

    def __init__(self, enabled=True, allow=None):
        self.enabled = enabled
        self._allow = allow  # None => every event allowed
        self.sent = []
        self.sent_events = []

    def event_enabled(self, event):
        if not self.enabled:
            return False
        return True if self._allow is None else event in self._allow

    def send(self, text, event=""):
        self.sent.append(text)
        self.sent_events.append(event)
        return True


def _svc(notifier=None, announce_online=True, **kw):
    notifier = notifier if notifier is not None else _FakeNotifier()
    kw.setdefault("worker_monitor", WorkerPresenceMonitor(offline_after=300, recovery_after=120))
    kw.setdefault("host_label", "")
    svc = AlertService(notifier=notifier, **kw)
    # The one-shot "stack online" ping fires on the first evaluate; mark it already sent so it
    # doesn't perturb the per-signal tests. TestStackOnline opts out to exercise it.
    if announce_online:
        svc._announced_online = True
    return svc


def _ev(
    svc,
    *,
    monero_down=False,
    monero_stale=False,
    tari_down=False,
    tari_required=True,
    miner_released=True,
    workers=(),
    workers_expected=False,
    disk_percent=0,
    db_healthy=True,
    db_reset_seq=0,
    db_reset_detail=None,
    xvb_enabled=False,
    shares_in_window=0,
    clearnet_active=False,
    xvb_registration_state="",
    update_available=False,
    low_hr_warning=False,
    hugepages_reserved=True,
    low_ram=False,
    observed_wallet="",
    reject_rate_1h=None,
    blocks_found_total=0,
    block_height=0,
    containers=None,
    now=0,
):
    return svc.evaluate(
        monero_down=monero_down,
        monero_stale=monero_stale,
        tari_down=tari_down,
        tari_required=tari_required,
        miner_released=miner_released,
        workers=list(workers),
        workers_expected=workers_expected,
        disk_percent=disk_percent,
        db_healthy=db_healthy,
        db_reset_seq=db_reset_seq,
        db_reset_detail=db_reset_detail,
        xvb_enabled=xvb_enabled,
        shares_in_window=shares_in_window,
        clearnet_active=clearnet_active,
        xvb_registration_state=xvb_registration_state,
        update_available=update_available,
        low_hr_warning=low_hr_warning,
        hugepages_reserved=hugepages_reserved,
        low_ram=low_ram,
        observed_wallet=observed_wallet,
        reject_rate_1h=reject_rate_1h,
        blocks_found_total=blocks_found_total,
        block_height=block_height,
        containers=containers,
        now=now,
    )


def _keys(alerts):
    return [k for k, _ in alerts]


def _kv_store():
    """A dict-backed stand-in for StateManager's kv_store (#375)."""
    store = {}
    return store, store.get, lambda k, v: store.__setitem__(k, str(v))


_W_A = "4A" + "a" * 93

_W_B = "4B" + "b" * 93


class _StubContainerMonitor:
    """Scripted ContainerHealthMonitor stand-in: the debounce logic has its own unit tests
    (test_container_health.py); here we only prove the edge → event/message mapping."""

    def __init__(self, edges=()):
        self.edges = list(edges)
        self.fed = []

    def update(self, states, now=None):
        self.fed.append(states)
        return self.edges


_PROCESS_SIGNALS = dict(
    tari_down=False,
    tari_required=True,
    miner_released=True,
    workers=[],
    workers_expected=False,
)


def _fake_localtime(hour, minute, yday=100, year=2026):
    """A time.localtime stand-in with just the fields maybe_daily_summary reads."""
    return lambda _now: SimpleNamespace(tm_year=year, tm_yday=yday, tm_hour=hour, tm_min=minute)


def _daily_svc(daily_time="08:00", notifier=None):
    notifier = notifier if notifier is not None else _FakeNotifier()
    return AlertService(
        notifier=notifier,
        worker_monitor=WorkerPresenceMonitor(),
        host_label="",
        daily_time=daily_time,
    )


__all__ = [name for name in globals() if not name.startswith("__")]
