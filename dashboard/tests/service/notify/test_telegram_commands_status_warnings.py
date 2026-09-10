# ruff: noqa: F403, F405
from tests.service.notify._telegram_commands_support import *  # noqa: F403


class TestStatusWarnings:
    """/status surfaces the same warning/error badges as the dashboard top bar (#104), reusing
    build_badges so the two never drift; informational states ('Syncing…') are excluded."""

    def test_bad_and_flagged_warn_badges_included_stripped(self, monkeypatch):
        # Low RAM (⚠ warn) + DB failing (bad) both surface; the leading ⚠ is stripped for the list.
        # Modes pinned full-local so the mode-aware floor (14) makes 8 GB a real warning.
        import mining_dashboard.web.views.xvb_views as xvb_mod

        monkeypatch.setattr(xvb_mod, "monero_is_local", lambda: True)
        monkeypatch.setattr(xvb_mod, "tari_is_local", lambda: True)
        warnings = tc.status_warnings(
            {"system": {"memory": {"total_gb": 8}}}, _metrics(), db_healthy=False
        )
        assert "Low RAM (8 GB)" in warnings
        assert "DB write failing" in warnings
        assert not any(w.startswith("⚠") for w in warnings)

    def test_informational_states_excluded(self):
        # 'Syncing…' / 'Miner held' are warn-variant but informational (no ⚠) — not warnings.
        warnings = tc.status_warnings(
            {"miner_held": True}, _metrics(global_syncing=True), db_healthy=True
        )
        assert warnings == []

    def test_healthy_is_empty(self):
        assert tc.status_warnings({}, _metrics(), db_healthy=True) == []

    def test_format_status_lists_warnings(self):
        text = tc.format_status(
            _metrics(), True, warnings=["Low RAM (8 GB)", "HugePages not reserved"]
        )
        assert "⚠️ Warnings:" in text
        assert "• Low RAM (8 GB)" in text
        assert "• HugePages not reserved" in text

    def test_format_status_all_clear(self):
        text = tc.format_status(_metrics(), True, warnings=[])
        assert "✅ No warnings." in text
