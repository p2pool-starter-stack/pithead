from mining_dashboard.service.health.node_alert import (
    TITLE,
    build_node_alert,
    tor_heal_status,
)
from mining_dashboard.service.health.tor_heal import (
    BROKEN_AFTER_SEC,
    COOLDOWN_SEC,
    MAX_ATTEMPTS,
    TorEgressHealer,
)

RED = {"level": "red", "reasons": ["0 outgoing peers for 12 min"]}


class _Clock:
    t = 1000.0

    def __call__(self):
        return self.t


def _healer(enabled=True):
    clock = _Clock()
    return TorEgressHealer(None, enabled=enabled, clock=clock, restart_monerod=False), clock


def _data(health=None, heal=None):
    return {"monero_sync": {"health": health or {"level": "green"}}, "tor_heal": heal or {}}


def test_disabled_healer_reports_only_that():
    healer, _ = _healer(enabled=False)
    assert tor_heal_status(healer) == {"enabled": False}


def test_green_monero_and_healthy_tor_raise_nothing():
    assert build_node_alert(_data()) is None
    assert build_node_alert({}) is None


def test_red_monero_verdict_names_the_node_offline_with_its_reasons():
    alert = build_node_alert(_data(RED))
    assert alert["title"] == TITLE == "Monero node offline"
    assert alert["reasons"] == RED["reasons"]
    assert alert["heal"] == []


def test_enabled_heal_with_no_action_says_so():
    healer, _ = _healer()
    alert = build_node_alert(_data(RED, tor_heal_status(healer)))
    assert alert["heal"] == ["Tor auto-heal: no action taken yet."]


def test_short_egress_failure_is_not_yet_an_alert():
    healer, clock = _healer()
    healer.decide(False, clock.t)
    clock.t += BROKEN_AFTER_SEC - 1
    healer.decide(False, clock.t)
    assert build_node_alert(_data(heal=tor_heal_status(healer))) is None


def test_egress_failure_past_the_broken_window_alerts_without_a_monero_verdict():
    healer, clock = _healer()
    healer.decide(False, clock.t)
    clock.t += BROKEN_AFTER_SEC
    assert healer.decide(False, clock.t) == "heal"
    healer._recovery_step = "NEWNYM"
    clock.t += 60
    alert = build_node_alert(_data(heal=tor_heal_status(healer)))
    assert alert["reasons"] == ["Tor clearnet egress has failed for 16 min"]
    assert alert["heal"] == [
        f"Tor auto-heal last action: NEWNYM, 1 min ago (attempt 1 of {MAX_ATTEMPTS}).",
        f"Next action after a {COOLDOWN_SEC // 60 - 1} min cooldown.",
    ]


def test_spent_attempt_cap_says_it_stopped():
    healer, clock = _healer()
    healer.decide(False, clock.t)
    for _ in range(MAX_ATTEMPTS):
        clock.t += BROKEN_AFTER_SEC if healer._attempts == 0 else COOLDOWN_SEC
        assert healer.decide(False, clock.t) == "heal"
    alert = build_node_alert(_data(RED, tor_heal_status(healer)))
    assert alert["heal"][0].startswith("Tor auto-heal last action: recovery attempt")
    assert alert["heal"][1].startswith(f"Tor auto-heal stopped after {MAX_ATTEMPTS} attempts")
    assert "./pithead doctor" in alert["heal"][1]
