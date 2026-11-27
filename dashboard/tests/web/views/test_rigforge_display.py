"""Unit tests for the RigForge worker-list chips and Worker Inspect rows (#235, #507, #3031)."""

from datetime import UTC, datetime

from mining_dashboard.web.views.infra_views import _rigforge_display, build_workers


def _fresh(report):
    return {"generated_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"), **report}


class TestRigForgeDisplay:
    """The RigForge enriched-feed builder (#235). Parsed block in → {version, chips, stats} out;
    each metric emitted only when its data is present, so nothing renders for a plain-xmrig worker.
    ``stats`` carries every metric as label/value for the Worker Inspect detail table (#507);
    ``chips`` is the subset the worker list shows (#3031): alarms plus live power and temperature."""

    def _chip_texts(self, disp):
        return [c["text"] for c in disp["chips"]]

    def _stats(self, disp):
        return {s["label"]: s for s in disp["stats"]}

    def _display(self, report):
        return _rigforge_display(_fresh(report))

    def test_none_for_plain_xmrig(self):
        assert _rigforge_display(None) is None

    def test_build_workers_passes_none_for_plain_xmrig(self):
        # A worker with no parsed rigforge block carries `rigforge: None` — the client renders
        # nothing extra, exactly as before the enriched feed existed.
        row = build_workers(
            [{"name": "r", "ip": "1.1.1.1", "status": "online", "active_pool": "3333"}]
        )[0]
        assert row["rigforge"] is None

    def test_full_block_emits_version_and_chips(self):
        parsed = {
            "version": "1.7.0",
            "miner_down": False,
            "power": {"watts": 142.0, "hs_per_watt": 86.9},
            "tune": {"target": "perf", "autotune_enabled": True, "autotune_next": "Sun 03:00"},
            "health": {
                "governor": "performance",
                "throttling": False,
                "board": "ProArt X670E",
                "hugepages_total": 1280,
            },
            "watchdog": {"enabled": True, "thermal_hold": False, "temp_c": 62, "max_temp_c": 85},
        }
        disp = self._display(parsed)
        assert disp["version"] == "1.7.0"
        # A healthy rig lists only its live numbers; static detail stays in Worker Inspect (#3031).
        assert self._chip_texts(disp) == ["142 W", "62°C"]
        titles = {c["text"]: c["title"] for c in disp["chips"]}
        assert titles["142 W"] == "Power draw / efficiency: 142 W · 86.9 H/s·W"
        assert titles["62°C"] == "Watchdog temperature / ceiling: 62°C / 85°C"

        # The detail table (#507) keeps every metric as a label/value pair.
        assert len(disp["stats"]) == 7
        stats = self._stats(disp)
        assert stats["Governor"]["value"] == "performance"
        assert stats["Governor"]["variant"] == "ok"
        assert stats["HugePages"]["value"] == "1280"
        assert stats["Mainboard"]["value"] == "ProArt X670E"
        assert stats["Power / efficiency"]["value"] == "142 W · 86.9 H/s·W"
        assert stats["Tuning target"]["value"] == "perf"
        assert stats["Autotune"]["value"] == "Sun 03:00"
        assert stats["Temp / max"]["value"] == "62°C / 85°C"

    def test_warn_rig_keeps_warn_chip_in_list(self):
        disp = self._display(
            {
                "version": "1.7.0",
                "miner_down": False,
                "power": {"watts": 142.0, "hs_per_watt": 86.9},
                "tune": {"target": "perf", "autotune_enabled": True, "autotune_next": "Sun 03:00"},
                "health": {
                    "governor": "powersave",
                    "throttling": False,
                    "board": "ProArt X670E",
                    "hugepages_total": 1280,
                },
                "watchdog": {"enabled": True, "thermal_hold": False, "temp_c": 62},
            }
        )
        assert self._chip_texts(disp) == ["gov: powersave", "142 W", "62°C"]
        assert "Governor" in self._stats(disp) and len(disp["stats"]) == 7

    def test_stats_split_label_from_value_and_colour_warn_states(self):
        # The label/value split powers the detail table; a bad/warn metric colours its own value.
        disp = self._display(
            {
                "version": "1.7.0",
                "miner_down": True,
                "power": {"watts": None, "hs_per_watt": None},
                "tune": {"target": None, "autotune_enabled": False, "autotune_next": None},
                "health": {
                    "governor": "powersave",
                    "throttling": True,
                    "board": None,
                    "hugepages_total": None,
                },
                "watchdog": {"enabled": False},
            }
        )
        stats = self._stats(disp)
        assert stats["Miner"]["value"] == "down" and stats["Miner"]["variant"] == "bad"
        assert stats["CPU"]["value"] == "throttling" and stats["CPU"]["variant"] == "bad"
        assert stats["Governor"]["value"] == "powersave"
        assert stats["Governor"]["variant"] == "warn"

    def test_stats_empty_when_no_metrics_present(self):
        disp = self._display(
            {
                "version": None,
                "miner_down": False,
                "power": {"watts": None, "hs_per_watt": None},
                "tune": {"target": None, "autotune_enabled": False, "autotune_next": None},
                "health": {
                    "governor": None,
                    "throttling": None,
                    "board": None,
                    "hugepages_total": None,
                },
                "watchdog": {"enabled": False, "thermal_hold": None, "temp_c": None},
            }
        )
        assert disp["stats"] == []

    def test_throttling_and_bad_governor_flag(self):
        disp = self._display(
            {
                "version": "1.7.0",
                "miner_down": False,
                "power": {"watts": None, "hs_per_watt": None},
                "tune": {"target": None, "autotune_enabled": False, "autotune_next": None},
                "health": {
                    "governor": "powersave",
                    "throttling": True,
                    "board": None,
                    "hugepages_total": None,
                },
                "watchdog": {"enabled": False},
            }
        )
        chips = {c["text"]: c["variant"] for c in disp["chips"]}
        assert chips["throttling"] == "bad"
        assert chips["gov: powersave"] == "warn"
        assert len(disp["stats"]) == len(disp["chips"])

    def test_nullable_fields_emit_no_chip(self):
        # No RAPL, no governor, disabled watchdog, no tune → only the fields that exist render.
        disp = self._display(
            {
                "version": None,
                "miner_down": False,
                "power": {"watts": None, "hs_per_watt": None},
                "tune": {"target": None, "autotune_enabled": False, "autotune_next": None},
                "health": {
                    "governor": None,
                    "throttling": None,
                    "board": None,
                    "hugepages_total": None,
                },
                "watchdog": {"enabled": False, "thermal_hold": None, "temp_c": None},
            }
        )
        assert disp["version"] is None
        assert disp["chips"] == []

    def test_miner_down_chip(self):
        disp = self._display(
            {
                "version": "1.7.0",
                "miner_down": True,
                "power": {"watts": None, "hs_per_watt": None},
                "tune": {"target": None, "autotune_enabled": False, "autotune_next": None},
                "health": {
                    "governor": None,
                    "throttling": None,
                    "board": None,
                    "hugepages_total": None,
                },
                "watchdog": {"enabled": False},
            }
        )
        assert disp["miner_down"] is True
        assert disp["chips"][0]["text"] == "miner down"
        assert disp["chips"][0]["variant"] == "bad"

    def test_thermal_hold_wins_over_temp_chip(self):
        disp = self._display(
            {
                "version": "1.7.0",
                "miner_down": False,
                "power": {"watts": None, "hs_per_watt": None},
                "tune": {"target": None, "autotune_enabled": False, "autotune_next": None},
                "health": {
                    "governor": None,
                    "throttling": None,
                    "board": None,
                    "hugepages_total": None,
                },
                "watchdog": {"enabled": True, "thermal_hold": True, "temp_c": 90, "max_temp_c": 85},
            }
        )
        texts = self._chip_texts(disp)
        assert "thermal hold" in texts
        assert not any("°C" in t for t in texts)  # the hold chip replaces the temp chip

    def test_list_chip_for_efficiency_only_and_temp_without_ceiling(self):
        disp = self._display(
            {
                "power": {"watts": None, "hs_per_watt": 86.9},
                "watchdog": {"enabled": True, "temp_c": 62},
            }
        )
        assert self._chip_texts(disp) == ["86.9 H/s·W", "62°C"]
        assert self._stats(disp)["Temp / max"]["value"] == "62°C"
