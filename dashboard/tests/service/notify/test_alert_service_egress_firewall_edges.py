# ruff: noqa: F401, F405
from tests.service.notify._alert_service_support import *  # noqa: F405

from mining_dashboard.service.network.egress_status import (
    ENFORCED,
    WATCHDOG_CLEAN,
    WATCHDOG_LEAKING,
    WATCHDOG_NOT_OBSERVED,
)

EVT = AlertService.EVT_CLEARNET_EXPOSED
WLEVT = AlertService.EVT_EGRESS_WATCHDOG_LEAK


class TestEgressFirewallEdges:
    def test_missing_then_restored_sends_one_of_each(self):
        svc = _svc()
        assert _ev(svc, egress_firewall="enforced") == []
        ((key, text),) = _ev(svc, egress_firewall="missing")
        assert key == EVT
        assert "firewall MISSING" in text and "pithead up" in text
        assert _ev(svc, egress_firewall="missing") == []
        ((key, text),) = _ev(svc, egress_firewall="enforced")
        assert key == EVT
        assert "restored" in text
        assert _ev(svc, egress_firewall="enforced") == []

    def test_a_dashboard_starting_on_a_missing_firewall_alerts_at_once(self):
        assert _keys(_ev(_svc(), egress_firewall="missing")) == [EVT]

    def test_a_fresh_enforced_start_is_silent(self):
        assert _ev(_svc(), egress_firewall="enforced") == []

    def test_unverified_sends_nothing_and_keeps_the_verdict(self):
        svc = _svc()
        assert _keys(_ev(svc, egress_firewall="missing")) == [EVT]
        assert _ev(svc, egress_firewall="unverified") == []
        assert _ev(svc, egress_firewall="missing") == []
        assert _ev(svc, egress_firewall="unverified") == []
        assert _keys(_ev(svc, egress_firewall="enforced")) == [EVT]
        assert _ev(_svc(), egress_firewall="unverified") == []

    def test_opting_out_resets_without_a_message(self):
        svc = _svc()
        assert _keys(_ev(svc, egress_firewall="missing")) == [EVT]
        assert _ev(svc, egress_firewall=None) == []
        assert _keys(_ev(svc, egress_firewall="missing")) == [EVT]

    def test_it_rides_the_clearnet_exposed_toggle(self):
        svc = _svc(notifier=_FakeNotifier(allow={"node_down"}))
        assert _ev(svc, egress_firewall="missing") == []

    def test_the_alarm_is_an_incident_and_the_recovery_is_not(self):
        svc = _svc()
        _ev(svc, egress_firewall="missing")
        _ev(svc, egress_firewall="enforced")
        assert svc.drain_incidents() == {EVT: 1}

    async def test_process_reads_the_host_verdict_itself(self, monkeypatch):
        monkeypatch.setattr(alert_mod, "live_firewall_state", lambda: "missing")
        notifier = _FakeNotifier()
        await _svc(notifier=notifier).process(
            monero_down=False,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
        )
        assert notifier.sent_events == [EVT]


class TestEgressWatchdogEdges:
    def test_clean_to_leaking_fires_alert(self):
        svc = _svc()
        assert _ev(svc, watchdog=WATCHDOG_CLEAN) == []
        result = _ev(svc, watchdog=WATCHDOG_LEAKING)
        assert len(result) == 1
        assert result[0][0] == WLEVT
        assert "non-Tor egress" in result[0][1]

    def test_leaking_to_clean_fires_recovery(self):
        svc = _svc()
        _ev(svc, watchdog=WATCHDOG_LEAKING)
        result = _ev(svc, watchdog=WATCHDOG_CLEAN)
        assert len(result) == 1
        assert result[0][0] == WLEVT
        assert "clean" in result[0][1].lower()

    def test_not_observed_drops_baseline(self):
        svc = _svc()
        assert _ev(svc, watchdog=WATCHDOG_NOT_OBSERVED) == []
        result = _ev(svc, watchdog=WATCHDOG_LEAKING)
        assert len(result) == 1
        assert result[0][0] == WLEVT

    def test_optout_clears_state(self):
        svc = _svc()
        _ev(svc, watchdog=WATCHDOG_CLEAN)
        assert _ev(svc, watchdog=None) == []
        result = _ev(svc, watchdog=WATCHDOG_LEAKING)
        assert len(result) == 1
        assert result[0][0] == WLEVT

    def test_stable_state_sends_nothing(self):
        svc = _svc()
        _ev(svc, watchdog=WATCHDOG_CLEAN)
        assert _ev(svc, watchdog=WATCHDOG_CLEAN) == []
        _ev(svc, watchdog=WATCHDOG_LEAKING)
        assert _ev(svc, watchdog=WATCHDOG_LEAKING) == []

    def test_leaking_is_an_incident_and_recovery_is_not(self):
        svc = _svc()
        _ev(svc, watchdog=WATCHDOG_LEAKING)
        _ev(svc, watchdog=WATCHDOG_CLEAN)
        assert svc.drain_incidents() == {WLEVT: 1}

    def test_watchdog_with_enforced_firewall_still_alerts_on_leak(self):
        svc = _svc()
        assert _ev(svc, egress_firewall=ENFORCED, watchdog=WATCHDOG_CLEAN) == []
        result = _ev(svc, egress_firewall=ENFORCED, watchdog=WATCHDOG_LEAKING)
        assert len(result) == 1
        assert result[0][0] == WLEVT
