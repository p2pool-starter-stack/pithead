"""Tor egress recovery guards: isolated probes, bounded refresh, final restart."""

from unittest.mock import AsyncMock, patch

import pytest

from mining_dashboard.service.health.tor_heal import (
    BROKEN_AFTER_SEC,
    COOLDOWN_SEC,
    MAX_ATTEMPTS,
    PROBE_INTERVAL_SEC,
    RECOVERY_CONFIRM_PROBES,
    TorEgressHealer,
)


class _Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


class _FakeDocker:
    """Records stop/start calls; always succeeds."""

    def __init__(self):
        self.calls = []

    async def stop(self, container, **kwargs):
        self.calls.append(("stop", container))
        return True

    async def start(self, container, **kwargs):
        self.calls.append(("start", container))
        return True


@pytest.fixture(autouse=True)
def _monerod_running():
    """The heal cycles monerod only when the read proxy says it runs (#2749); running by default."""
    with patch(
        "mining_dashboard.service.health.tor_heal.get_container_health",
        AsyncMock(return_value={"monerod": {"running": True}}),
    ):
        yield


def _healer(clock=None, enabled=True, probe=None, notify=None, docker=None, restart_monerod=None):
    # restart_monerod=None exercises the config default: the test env's MONERO_NODE_HOST equals
    # LOCAL_MONERO_HOST (both defaults), i.e. a LOCAL node — heals also cycle monerod (#972).
    return TorEgressHealer(
        docker or _FakeDocker(),
        enabled=enabled,
        probe=probe or (lambda: (False, "test probe")),
        notify=notify,
        clock=clock or _Clock(),
        restart_monerod=restart_monerod,
    )


def _break_egress(healer, clock):
    """Feed failing probes until the sustained threshold is crossed; the next decide may heal."""
    healer.decide(False, clock.t)
    clock.t += BROKEN_AFTER_SEC


class TestDecide:
    def test_heals_when_broken_sustained_and_no_cooldown(self):
        clock = _Clock()
        h = _healer(clock)
        _break_egress(h, clock)
        assert h.decide(False, clock.t) == "heal"

    def test_transient_blip_never_heals(self):
        clock = _Clock()
        h = _healer(clock)
        h.decide(False, clock.t)
        clock.t += BROKEN_AFTER_SEC - 1
        assert h.decide(False, clock.t) is None

    def test_blip_that_recovers_resets_the_streak(self):
        clock = _Clock()
        h = _healer(clock)
        h.decide(False, clock.t)
        clock.t += BROKEN_AFTER_SEC - 1
        assert h.decide(True, clock.t) is None  # recovered on its own: no heal, no alert
        # A new failure starts a fresh streak — the old one must not carry over.
        assert h.decide(False, clock.t) is None
        clock.t += BROKEN_AFTER_SEC - 1
        assert h.decide(False, clock.t) is None

    def test_no_second_heal_during_cooldown(self):
        clock = _Clock()
        h = _healer(clock)
        _break_egress(h, clock)
        assert h.decide(False, clock.t) == "heal"
        clock.t += COOLDOWN_SEC - 1
        assert h.decide(False, clock.t) is None  # still broken, but inside the cooldown

    def test_second_heal_after_cooldown(self):
        clock = _Clock()
        h = _healer(clock)
        _break_egress(h, clock)
        assert h.decide(False, clock.t) == "heal"
        clock.t += COOLDOWN_SEC
        assert h.decide(False, clock.t) == "heal"

    def test_budget_exhausted_stops_healing_and_keeps_warning(self):
        clock = _Clock()
        h = _healer(clock)
        _break_egress(h, clock)
        for _ in range(MAX_ATTEMPTS):
            assert h.decide(False, clock.t) == "heal"
            clock.t += COOLDOWN_SEC
        # Budget spent: from here on it's warn-only, forever, no matter how much time passes.
        assert h.decide(False, clock.t) == "exhausted"
        clock.t += 100 * COOLDOWN_SEC
        assert h.decide(False, clock.t) == "exhausted"

    def test_recovery_needs_sustained_ok_before_resetting_the_budget(self):
        # After a heal, ONE OK probe is not enough — recovery must be sustained
        # (RECOVERY_CONFIRM_PROBES consecutive OKs) before the outage closes and the budget
        # resets. This is the #424-review fix: a lone lucky 204 must not refill the cap.
        clock = _Clock()
        h = _healer(clock)
        _break_egress(h, clock)
        assert h.decide(False, clock.t) == "heal"
        clock.t += PROBE_INTERVAL_SEC
        # First OK: provisional only, no "recovered" yet.
        for _ in range(RECOVERY_CONFIRM_PROBES - 1):
            assert h.decide(True, clock.t) is None
            clock.t += PROBE_INTERVAL_SEC
        # The confirming OK closes the outage.
        assert h.decide(True, clock.t) == "recovered"
        # Only NOW does the next outage get a fresh budget.
        _break_egress(h, clock)
        assert h.decide(False, clock.t) == "heal"

    def test_flapping_egress_cannot_refill_the_budget(self):
        # The issue's own scenario: an overloaded Tor with egress flapping. A single OK between
        # failures must NOT reset the cap, or "max 3 per outage" becomes 3-every-cooldown forever.
        clock = _Clock()
        h = _healer(clock)
        _break_egress(h, clock)
        for _ in range(MAX_ATTEMPTS):
            assert h.decide(False, clock.t) == "heal"
            clock.t += PROBE_INTERVAL_SEC
            # One lucky probe succeeds, then egress drops again before recovery is confirmed.
            assert h.decide(True, clock.t) is None  # provisional, budget preserved
            clock.t += COOLDOWN_SEC
        # Budget is spent and a lone OK never refilled it: warn-only, not another heal.
        assert h.decide(False, clock.t) == "exhausted"

    @pytest.mark.parametrize(
        "stopped,started", [(False, False), (False, True), (True, False), (True, True)]
    )
    async def test_restart_outcomes_keep_budget_and_record_start(self, stopped, started, caplog):
        clock = _Clock()
        docker = AsyncMock()
        docker.stop.return_value = stopped
        docker.start.return_value = started
        h = _healer(clock, docker=docker)
        h._attempts = MAX_ATTEMPTS - 1
        _break_egress(h, clock)
        with caplog.at_level("INFO", logger="TorHeal"):
            await h.check()
            assert h._attempts == MAX_ATTEMPTS
            assert h._last_attempt == clock.t
            assert docker.start.await_args_list[0].args == ("tor",)
            assert docker.start.await_count == (2 if started else 1)
            if started:
                assert docker.start.await_args_list[1].args == ("monerod",)
            expected = (
                "Tor restart"
                if stopped and started
                else "Tor start (stop unconfirmed)"
                if started
                else "Tor restart unconfirmed"
            )
            assert h._recovery_step == expected
            clock.t += COOLDOWN_SEC
            await h.check()
            assert docker.start.await_count == (2 if started else 1)
            h._probe = lambda: (True, "fresh circuit answered")
            for _ in range(RECOVERY_CONFIRM_PROBES):
                clock.t += PROBE_INTERVAL_SEC
                await h.check()
        assert any(f"recovered following {expected}:" in r.message for r in caplog.records)
        assert not any("refunded" in r.message for r in caplog.records)
        assert h._attempts == 0

    def test_recovery_after_heal_reports_and_resets_the_budget(self):
        clock = _Clock()
        h = _healer(clock)
        _break_egress(h, clock)
        assert h.decide(False, clock.t) == "heal"
        clock.t += PROBE_INTERVAL_SEC
        for _ in range(RECOVERY_CONFIRM_PROBES):
            h.decide(True, clock.t)
            clock.t += PROBE_INTERVAL_SEC
        # The next outage gets a fresh budget and must re-earn the sustained threshold.
        _break_egress(h, clock)
        assert h.decide(False, clock.t) == "heal"

    def test_recovery_without_a_heal_is_silent(self):
        clock = _Clock()
        h = _healer(clock)
        assert h.decide(True, clock.t) is None


class TestCheck:
    async def test_disabled_is_a_total_noop(self):
        def probe():
            raise AssertionError("disabled healer must never probe")

        docker = _FakeDocker()
        h = _healer(enabled=False, probe=probe, docker=docker)
        await h.check()
        assert docker.calls == []

    async def test_refreshes_circuits_before_restarting_tor_and_monerod(self, caplog):
        # The tor restart kills monerod's SOCKS peers; the heal cycles monerod right after so
        # it re-dials (#972) — order matters: monerod must come back to a LIVE tor.
        clock = _Clock()
        docker = _FakeDocker()
        h = _healer(clock, probe=lambda: (False, "test probe"), docker=docker)
        with (
            patch(
                "mining_dashboard.service.health.tor_heal.control_service.submit", return_value="id"
            ),
            patch(
                "mining_dashboard.service.health.tor_heal.control_service.result",
                return_value={"status": "applied"},
            ),
            caplog.at_level("WARNING", logger="TorHeal"),
        ):
            await h.check()
            for _ in range(MAX_ATTEMPTS):
                clock.t += COOLDOWN_SEC
                await h.check()
        assert docker.calls == [
            ("stop", "tor"),
            ("start", "tor"),
            ("stop", "monerod"),
            ("start", "monerod"),
        ]
        assert any("Requesting NEWNYM" in r.message for r in caplog.records)
        assert any("Restarting Tor" in r.message for r in caplog.records)

    async def test_a_stopped_monerod_is_not_started(self):
        # #2749: a held monerod (LAN guard failed at boot) must stay down, or its LAN ports open.
        clock = _Clock()
        docker = _FakeDocker()
        h = _healer(clock, probe=lambda: (False, "test probe"), docker=docker)
        with (
            patch(
                "mining_dashboard.service.health.tor_heal.get_container_health",
                AsyncMock(return_value={"monerod": {"running": False}}),
            ),
            patch(
                "mining_dashboard.service.health.tor_heal.control_service.submit", return_value="id"
            ),
            patch(
                "mining_dashboard.service.health.tor_heal.control_service.result",
                return_value={"status": "applied"},
            ),
        ):
            await h.check()
            for _ in range(MAX_ATTEMPTS):
                clock.t += COOLDOWN_SEC
                await h.check()
        assert docker.calls == [("stop", "tor"), ("start", "tor")]

    async def test_remote_node_heal_touches_only_tor(self):
        # A remote monerod has no container here — the heal must stay tor-scoped.
        clock = _Clock()
        docker = _FakeDocker()
        h = _healer(
            clock, probe=lambda: (False, "test probe"), docker=docker, restart_monerod=False
        )
        with (
            patch(
                "mining_dashboard.service.health.tor_heal.control_service.submit", return_value="id"
            ),
            patch(
                "mining_dashboard.service.health.tor_heal.control_service.result",
                return_value={"status": "applied"},
            ),
        ):
            await h.check()
            for _ in range(MAX_ATTEMPTS):
                clock.t += COOLDOWN_SEC
                await h.check()
        assert docker.calls == [("stop", "tor"), ("start", "tor")]

    async def test_failed_monerod_cycle_warns_but_keeps_the_tor_attempt(self, caplog):
        # monerod failing to cycle must not refund the tor budget slot — the tor restart DID
        # happen; the warning points at the manual leg and the stale alert is the backstop.
        class _MonerodFailingDocker(_FakeDocker):
            async def start(self, container, **kwargs):
                self.calls.append(("start", container))
                return container != "monerod"

        clock = _Clock()
        docker = _MonerodFailingDocker()
        h = _healer(clock, probe=lambda: (False, "test probe"), docker=docker)
        with (
            patch(
                "mining_dashboard.service.health.tor_heal.control_service.submit", return_value="id"
            ),
            patch(
                "mining_dashboard.service.health.tor_heal.control_service.result",
                return_value={"status": "applied"},
            ),
            caplog.at_level("WARNING", logger="TorHeal"),
        ):
            await h.check()
            for _ in range(MAX_ATTEMPTS):
                clock.t += COOLDOWN_SEC
                await h.check()
        assert ("stop", "monerod") in docker.calls
        assert h._attempts == MAX_ATTEMPTS  # tor attempt kept, not refunded
        assert any("restart monerod" in r.message for r in caplog.records)

    async def test_exhausted_warns_but_never_attempts(self, caplog):
        clock = _Clock()
        docker = _FakeDocker()
        h = _healer(clock, probe=lambda: (False, "test probe"), docker=docker)
        with (
            patch(
                "mining_dashboard.service.health.tor_heal.control_service.submit", return_value="id"
            ),
            patch(
                "mining_dashboard.service.health.tor_heal.control_service.result",
                return_value={"status": "applied"},
            ),
        ):
            await h.check()
            for _ in range(MAX_ATTEMPTS):
                clock.t += max(BROKEN_AFTER_SEC, COOLDOWN_SEC)
                await h.check()
        assert len(docker.calls) == 4  # two circuit refreshes and one container restart
        with caplog.at_level("WARNING", logger="TorHeal"):
            clock.t += COOLDOWN_SEC
            await h.check()
        assert len(docker.calls) == 4  # no further restarts, ever
        assert any("STILL broken" in r.message for r in caplog.records)

    async def test_recovery_sends_the_one_time_notify(self):
        notes = []

        async def notify(text):
            notes.append(text)

        clock = _Clock()
        results = {"ok": False}
        h = _healer(
            clock, probe=lambda: (results["ok"], "first target; second circuit"), notify=notify
        )
        with (
            patch(
                "mining_dashboard.service.health.tor_heal.control_service.submit", return_value="id"
            ),
            patch(
                "mining_dashboard.service.health.tor_heal.control_service.result",
                return_value={"status": "applied"},
            ),
        ):
            await h.check()
            clock.t += BROKEN_AFTER_SEC
            await h.check()  # NEWNYM
            results["ok"] = True
            clock.t += COOLDOWN_SEC
            await h.check()  # observe host result and first confirming probe
        clock.t += PROBE_INTERVAL_SEC
        await h.check()  # recovered -> notify once
        clock.t += PROBE_INTERVAL_SEC
        await h.check()  # still fine -> silent
        assert len(notes) == 1
        assert "recovered following NEWNYM" in notes[0]
        assert "failed probes first target; second circuit" in notes[0]
        assert "recovery probe first target; second circuit" in notes[0]

    async def test_probe_or_restart_errors_never_escape(self):
        class _BoomDocker:
            async def stop(self, *a, **k):
                raise RuntimeError("proxy down")

            async def start(self, *a, **k):
                raise RuntimeError("proxy down")

        clock = _Clock()
        h = _healer(clock, probe=lambda: (False, "test probe"), docker=_BoomDocker())
        h._attempts = MAX_ATTEMPTS - 1
        await h.check()
        clock.t += BROKEN_AFTER_SEC
        await h.check()  # the failed restart must not raise into the data loop
