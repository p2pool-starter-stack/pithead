# ruff: noqa: F403, F405
from tests.service.notify._telegram_commands_support import *  # noqa: F403


class TestInfo:
    """/info — the 'about this stack' card: build version, update availability, Monero DB mode,
    P2Pool sidechain, and privacy (egress) posture. All facts the stack already computes."""

    def test_release_up_to_date_pruned_tor(self):
        out = tc.format_info(
            {"text": "v1.1.0", "dev": False},
            {"available": False},
            _metrics(monero_mode="Pruned", pool_type="Mini"),
            {"all_tor": True},
        )
        assert "Version: v1.1.0" in out and "(dev build)" not in out
        assert "✅ Up to date" in out
        assert "Monero DB: Pruned" in out
        assert "Sidechain: P2Pool Mini" in out
        assert "🧅 Tor-only" in out

    def test_dev_update_available_full_clearnet(self):
        out = tc.format_info(
            {"text": "dev · main @ abc1234", "dev": True},
            {"available": True, "latest": "v1.2.0"},
            _metrics(monero_mode="Full"),
            {"all_tor": False, "label": "2 clearnet egress path(s) exposing your IP"},
        )
        assert "(dev build)" in out
        assert "🆕 v1.2.0 available" in out
        assert "Monero DB: Full" in out
        assert "⚠️ 2 clearnet egress path(s)" in out

    def test_unknown_db_mode_and_missing_update(self):
        # monero_mode "Unknown" (remote/early) → no false Pruned/Full; update None → up to date.
        out = tc.format_info(
            {"text": "v1.1.0"}, None, _metrics(monero_mode="Unknown"), {"all_tor": True}
        )
        assert "Monero DB: unknown" in out
        assert "✅ Up to date" in out

    def test_reply_for_info_routes(self, monkeypatch):
        monkeypatch.setattr(tc, "resolve_version", lambda: {"text": "v1.1.0", "dev": False})
        monkeypatch.setattr(
            tc, "egress_posture_from_config", lambda: {"summary": {"all_tor": True}}
        )
        bot = _bot(monkeypatch, latest_data={"update": {"available": False}}, monero_mode="Pruned")
        out = bot.reply_for("/info")
        assert "📟 Pithead info" in out and "Version: v1.1.0" in out and "🧅 Tor-only" in out
