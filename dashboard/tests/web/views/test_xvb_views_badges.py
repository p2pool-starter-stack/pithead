# ruff: noqa: F403, F405
from tests.web.views._xvb_views_support import *  # noqa: F403


class TestBadges:
    def _texts(self, badges):
        return [b["text"] for b in badges]

    def test_syncing_shows_syncing_only(self, _metrics):
        out = build_badges({}, _metrics(global_syncing=True), "ok")
        assert "Syncing..." in self._texts(out)
        assert not any("P2POOL" in t for t in self._texts(out))

    def test_operational_shows_mode_and_pool(self, _metrics):
        out = build_badges({}, _metrics(mode="P2POOL", pool_type="Mini"), "ok")
        assert "P2POOL" in self._texts(out)
        assert "P2Pool Mini" in self._texts(out)

    def test_low_hr_badge(self, _metrics):
        out = build_badges({}, _metrics(low_hr_warning=True), "ok")
        assert any(b["variant"] == "warn" and "low for tier" in b["text"] for b in out)

    def test_no_share_badge_when_donating_without_a_share(self, _metrics):
        # XvB enabled + no PPLNS share => wins are skipped + a fail, regardless of tier (#158).
        out = build_badges({}, _metrics(xvb_enabled=True, shares_in_window=0), "ok")
        assert any("No PPLNS share" in b["text"] for b in out)

    def test_no_share_badge_absent_when_has_share_or_xvb_off(self, _metrics):
        # Has a share => no badge; XvB off => raffle moot, no badge.
        assert not any(
            "No PPLNS share" in t
            for t in self._texts(
                build_badges({}, _metrics(xvb_enabled=True, shares_in_window=3), "ok")
            )
        )
        assert not any(
            "No PPLNS share" in t
            for t in self._texts(
                build_badges({}, _metrics(xvb_enabled=False, shares_in_window=0), "ok")
            )
        )

    def test_xvb_registered_badge(self, _metrics):
        # registered_at set + clean state => a muted "✓" confirmation badge (#263).
        out = build_badges({}, _metrics(xvb_enabled=True, xvb_registered_at=1.0), "ok")
        assert any(b["text"] == "XvB raffle ✓" and b["variant"] == "outline" for b in out)

    def test_xvb_invalid_wallet_badge(self, _metrics):
        # Endpoint rejected the wallet => loud "bad" badge so the user fixes MONERO_WALLET_ADDRESS.
        out = build_badges({}, _metrics(xvb_enabled=True, xvb_registration_state="invalid"), "ok")
        assert any(b["variant"] == "bad" and "wallet rejected" in b["text"] for b in out)

    def test_xvb_failing_badge_takes_priority_over_checkmark(self, _metrics):
        # A real problem must not be masked by a stale registered_at.
        out = build_badges(
            {},
            _metrics(xvb_enabled=True, xvb_registration_state="failing", xvb_registered_at=1.0),
            "ok",
        )
        assert any(b["variant"] == "bad" and "failing" in b["text"] for b in out)
        assert not any("✓" in b["text"] for b in out)

    def test_no_xvb_registration_badge_when_disabled(self, _metrics):
        out = build_badges({}, _metrics(xvb_enabled=False, xvb_registered_at=1.0), "ok")
        assert not any("XvB raffle" in b["text"] for b in out)

    def test_node_down_and_rejected(self, _metrics, _sync):
        m = _metrics(monero=_sync(down=True), tari=_sync(down=True))
        out = build_badges({"workers_rejected": True}, m, "ok")
        t = self._texts(out)
        assert "monerod DOWN" in t and "Tari DOWN" in t and "Workers rejected" in t

    def test_miner_held(self, _metrics):
        out = build_badges({"miner_held": True}, _metrics(global_syncing=True), "ok")
        assert "Miner held (sync)" in self._texts(out)

    def test_fail_closed_held(self, _metrics):
        # #490: distinct badge from the sync-gate hold above — fires post-sync, only with
        # dashboard.fail_closed on.
        out = build_badges({"fail_closed_held": True}, _metrics(), "ok")
        assert any(b["variant"] == "bad" and "Miner held (fail-closed)" in b["text"] for b in out)

    def test_no_fail_closed_badge_by_default(self, _metrics):
        out = build_badges({}, _metrics(), "ok")
        assert not any("fail-closed" in b["text"] for b in out)

    def test_passive_tari_with_and_without_percent(self, _metrics, _sync):
        with_pct = build_badges(
            {"tari_syncing_passive": True}, _metrics(tari=_sync(percent=42)), "ok"
        )
        assert "Tari syncing 42%" in self._texts(with_pct)
        no_pct = build_badges({"tari_syncing_passive": True}, _metrics(tari=_sync(percent=0)), "ok")
        assert "Tari syncing" in self._texts(no_pct)

    def test_monero_pruned_badge(self, _metrics):
        out = build_badges({}, _metrics(monero_mode="Pruned"), "ok")
        assert any(b["text"] == "XMR Pruned" and b["variant"] == "outline" for b in out)

    def test_monero_full_badge(self, _metrics):
        out = build_badges({}, _metrics(monero_mode="Full"), "ok")
        assert any(b["text"] == "XMR Full" and b["variant"] == "outline" for b in out)

    def test_no_prune_badge_when_unknown(self, _metrics):
        out = build_badges({}, _metrics(monero_mode="Unknown"), "ok")
        assert not any("XMR" in b["text"] for b in out)

    def test_disk_badge_critical(self, _metrics):
        out = build_badges({"system": {"disk": {"percent": 96}}}, _metrics(), "ok")
        assert any(b["variant"] == "bad" and "Disk 96% full" in b["text"] for b in out)

    def test_disk_badge_warn(self, _metrics):
        out = build_badges({"system": {"disk": {"percent": 88}}}, _metrics(), "ok")
        assert any(b["variant"] == "warn" and "Disk 88% full" in b["text"] for b in out)

    def test_no_disk_badge_when_ample(self, _metrics):
        out = build_badges({"system": {"disk": {"percent": 50}}}, _metrics(), "ok")
        assert not any("Disk" in b["text"] for b in out)

    def test_no_disk_badge_when_missing(self, _metrics):
        # No system/disk data (e.g. an early poll) must not emit a spurious or crashing badge.
        out = build_badges({}, _metrics(), "ok")
        assert not any("Disk" in b["text"] for b in out)

    # --- Host-perf badges (#104): AVX2 / HugePages / low RAM, from live metrics -------------
    def test_hugepages_disabled_badge(self, _metrics):
        out = build_badges(
            {"system": {"hugepages": ["Disabled", "status-bad", "0/0"]}}, _metrics(), "ok"
        )
        assert any(b["variant"] == "warn" and "HugePages off" in b["text"] for b in out)

    def test_no_hugepages_badge_when_reserved(self, _metrics):
        for status in ("Allocated", "Enabled", "Unknown"):  # only "Disabled" is a problem
            out = build_badges({"system": {"hugepages": [status, "", "1/2"]}}, _metrics(), "ok")
            assert not any("HugePages" in b["text"] for b in out), status

    def test_low_ram_badge_tracks_what_runs_locally(self, _metrics, monkeypatch):
        # The floor is MODE-AWARE: 8 GB is too little for a full-local stack, fine for a
        # coordinator whose nodes are remote — remote nodes take their appetite with them.
        import mining_dashboard.web.views.xvb_views as xvb_mod

        monkeypatch.setattr(xvb_mod, "monero_is_local", lambda: True)
        monkeypatch.setattr(xvb_mod, "tari_is_local", lambda: True)
        out = build_badges({"system": {"memory": {"total_gb": 8}}}, _metrics(), "ok")
        assert any(b["variant"] == "warn" and "Low RAM (8 GB)" in b["text"] for b in out)

        monkeypatch.setattr(xvb_mod, "monero_is_local", lambda: False)
        monkeypatch.setattr(xvb_mod, "tari_is_local", lambda: False)
        out = build_badges({"system": {"memory": {"total_gb": 8}}}, _metrics(), "ok")
        assert not any("Low RAM" in b["text"] for b in out)

    def test_low_ram_badge_counts_the_built_in_miner(self, _metrics, monkeypatch):
        # The Both role's risk case: both nodes local fits a 16 GB box (floor 14) — until the
        # built-in miner's own dataset joins them, when the same box honestly warns (floor 17).
        import mining_dashboard.config.config as cfg_mod
        import mining_dashboard.web.views.xvb_views as xvb_mod

        monkeypatch.setattr(xvb_mod, "monero_is_local", lambda: True)
        monkeypatch.setattr(xvb_mod, "tari_is_local", lambda: True)
        state = {"system": {"memory": {"total_gb": 15.6}}}
        assert not any("Low RAM" in b["text"] for b in build_badges(state, _metrics(), "ok"))

        monkeypatch.setattr(cfg_mod, "local_miner_enabled", lambda path=None: True)
        out = build_badges(state, _metrics(), "ok")
        assert any(b["variant"] == "warn" and "Low RAM (16 GB)" in b["text"] for b in out)

    def test_no_low_ram_badge_at_or_above_threshold_or_unknown(self, _metrics):
        # 15.6 is what a NOMINAL 16 GB machine actually reports (reserved memory, GiB-vs-GB) —
        # the documented minimum spec must never wear a permanent warning. Bench-reported.
        for total in (15.6, 16, 14):
            assert not any(
                "Low RAM" in b["text"]
                for b in build_badges({"system": {"memory": {"total_gb": total}}}, _metrics(), "ok")
            ), total
        # total 0 = couldn't read /proc/meminfo (not "0 GB of RAM") — no false badge.
        assert not any(
            "Low RAM" in b["text"]
            for b in build_badges({"system": {"memory": {"total_gb": 0}}}, _metrics(), "ok")
        )

    def test_memory_pressure_badge_keys_on_LIVE_availability_not_capacity(self, _metrics):
        # A spec box quietly idling wears nothing; a box down to its last GB warns — whatever
        # its size. Capacity says what it could do; pressure says what is happening.
        out = build_badges(
            {"system": {"memory": {"total_gb": 15.6, "available_gb": 0.8}}}, _metrics(), "ok"
        )
        assert any(b["variant"] == "warn" and "Memory pressure" in b["text"] for b in out)
        out = build_badges(
            {"system": {"memory": {"total_gb": 15.6, "available_gb": 8.0}}}, _metrics(), "ok"
        )
        assert not any("Memory pressure" in b["text"] for b in out)
        # An older payload without available_gb must not fabricate a pressure reading.
        out = build_badges({"system": {"memory": {"total_gb": 15.6}}}, _metrics(), "ok")
        assert not any("Memory pressure" in b["text"] for b in out)

    def test_avx2_missing_badge(self, _metrics):
        out = build_badges({"system": {"avx2": False}}, _metrics(), "ok")
        assert any(b["variant"] == "warn" and "No AVX2" in b["text"] for b in out)

    def test_no_avx2_badge_when_present_or_unknown(self, _metrics):
        assert not any(
            "AVX2" in b["text"] for b in build_badges({"system": {"avx2": True}}, _metrics(), "ok")
        )
        # None = couldn't determine (non-Linux / unreadable) — stay silent, don't cry wolf.
        assert not any(
            "AVX2" in b["text"] for b in build_badges({"system": {"avx2": None}}, _metrics(), "ok")
        )
