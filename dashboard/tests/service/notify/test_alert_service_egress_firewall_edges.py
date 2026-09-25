# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403

EVT = AlertService.EVT_CLEARNET_EXPOSED


class TestEgressFirewallEdges:
    """#2599: one message into ``missing``, one back to ``enforced``, never one per check."""

    def test_missing_then_restored_sends_one_of_each(self):
        svc = _svc()
        assert _ev(svc, egress_firewall="enforced") == []
        ((key, text),) = _ev(svc, egress_firewall="missing")
        assert key == EVT
        assert "firewall MISSING" in text and "pithead up" in text
        assert _ev(svc, egress_firewall="missing") == []  # the next check does not repeat it
        ((key, text),) = _ev(svc, egress_firewall="enforced")
        assert key == EVT
        assert "restored" in text
        assert _ev(svc, egress_firewall="enforced") == []

    def test_a_dashboard_starting_on_a_missing_firewall_alerts_at_once(self):
        # The #2460 reboot: the containers came back without the rules and nothing ever said so.
        assert _keys(_ev(_svc(), egress_firewall="missing")) == [EVT]

    def test_a_fresh_enforced_start_is_silent(self):
        assert _ev(_svc(), egress_firewall="enforced") == []

    def test_unverified_sends_nothing_and_keeps_the_verdict(self):
        svc = _svc()
        assert _keys(_ev(svc, egress_firewall="missing")) == [EVT]
        assert _ev(svc, egress_firewall="unverified") == []
        assert _ev(svc, egress_firewall="missing") == []  # a gap in the checks is not a new alarm
        assert _ev(svc, egress_firewall="unverified") == []
        assert _keys(_ev(svc, egress_firewall="enforced")) == [EVT]  # only a real recovery
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
        # The data loop passes no egress_firewall; process() asks the host file, evaluate stays pure.
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
