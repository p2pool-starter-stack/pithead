# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestDailySummary:
    async def test_fires_at_target_once_per_day(self, monkeypatch):
        n = _FakeNotifier()
        svc = _daily_svc(notifier=n)
        prov = lambda: "digest"  # noqa: E731
        # Before the target time → nothing.
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(7, 59))
        assert await svc.maybe_daily_summary(0, prov) is None
        # At the target → fires once.
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(8, 0))
        assert await svc.maybe_daily_summary(0, prov) == "digest"
        assert n.sent == ["digest"]
        # Later the same day → no repeat.
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(9, 30))
        assert await svc.maybe_daily_summary(0, prov) is None
        # Next day at the target → fires again.
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(8, 0, yday=101))
        assert await svc.maybe_daily_summary(0, prov) == "digest"
        assert n.sent == ["digest", "digest"]

    async def test_late_start_waits_for_next_day(self, monkeypatch):
        svc = _daily_svc()
        prov = lambda: "digest"  # noqa: E731
        # First observation is already past 08:00 → don't replay today.
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(10, 0))
        assert await svc.maybe_daily_summary(0, prov) is None
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(23, 0))
        assert await svc.maybe_daily_summary(0, prov) is None
        # Next day at 08:00 → fires.
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(8, 0, yday=101))
        assert await svc.maybe_daily_summary(0, prov) == "digest"

    async def test_malformed_time_disables(self, monkeypatch):
        svc = _daily_svc(daily_time="not-a-time")
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(8, 0))
        assert await svc.maybe_daily_summary(0, lambda: "x") is None

    def test_out_of_range_time_parses_to_none(self):
        # Well-formed HH:MM but out of the 24h/60m range must disable the digest, not wrap around to a
        # bogus fire time — "25:00" would otherwise never match localtime and silently never fire.
        for bad in ("25:00", "12:60", "12", "-1:00"):
            assert alert_mod._parse_hhmm(bad) is None, bad

    async def test_gated_off_by_event_toggle(self, monkeypatch):
        # daily_summary not in the allow-set → the notifier reports it disabled.
        svc = _daily_svc(notifier=_FakeNotifier(allow=set()))
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(8, 0))
        assert await svc.maybe_daily_summary(0, lambda: "x") is None

    async def test_provider_error_is_swallowed_and_marks_day_done(self, monkeypatch):
        n = _FakeNotifier()
        svc = _daily_svc(notifier=n)

        def boom():
            raise RuntimeError("bad build")

        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(8, 0))
        assert await svc.maybe_daily_summary(0, boom) is None
        assert n.sent == []
        # Marked done for today even though the build failed → no retry storm.
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(8, 5))
        assert await svc.maybe_daily_summary(0, lambda: "digest") is None
