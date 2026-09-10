# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestHostAdvisories:
    """Persistent host-perf advisories (#104): unlike the transient edges, these fire on the FIRST
    observation of the problem (a stable bad box would never 'transition'), stay quiet while it
    persists, and — for HugePages — clear when fixed. They are not tallied as daily incidents."""

    def test_hugepages_not_reserved_fires_once_then_recovers(self):
        svc = _svc()
        # First cycle already bad → fires (not seed-silent).
        assert _keys(_ev(svc, hugepages_reserved=False)) == [AlertService.EVT_HUGEPAGES]
        # Persists → silent.
        assert _keys(_ev(svc, hugepages_reserved=False)) == []
        # Reboot applied HugePages → one recovery edge.
        assert _keys(_ev(svc, hugepages_reserved=True)) == [AlertService.EVT_HUGEPAGES]
        assert _keys(_ev(svc, hugepages_reserved=True)) == []

    def test_healthy_hugepages_never_fires(self):
        svc = _svc()
        assert _keys(_ev(svc, hugepages_reserved=True)) == []
        assert _keys(_ev(svc, hugepages_reserved=True)) == []

    def test_low_ram_fires_once_no_recovery(self):
        svc = _svc()
        assert _keys(_ev(svc, low_ram=True)) == [AlertService.EVT_LOW_RAM]
        assert _keys(_ev(svc, low_ram=True)) == []  # persists, silent
        # RAM "recovering" (unlikely at runtime) is silent — no false good-news ping.
        assert _keys(_ev(svc, low_ram=False)) == []

    def test_advisories_not_counted_as_incidents(self):
        # Static host facts shouldn't inflate the daily incident roll-up (#342).
        svc = _svc()
        _ev(svc, hugepages_reserved=False, low_ram=True)
        assert svc.drain_incidents() == {}

    def test_gated_off_by_toggle(self):
        svc = _svc(notifier=_FakeNotifier(allow={AlertService.EVT_NODE_DOWN}))
        assert _keys(_ev(svc, hugepages_reserved=False, low_ram=True)) == []
