# ruff: noqa: F403, F405
from tests.web.views._xvb_views_support import *  # noqa: F403


class TestEarningsVsActual:
    NOW = 1_760_000_000

    def test_combined_expected_folds_xvb_and_uses_the_window_average(self, _metrics):
        # ONE combined row (#817): expected = P2Pool linear (coeff_day × 30d-average × 30 — the
        # WINDOW's average, not the current 1h figure) + XvB's published per-day estimate × 30,
        # because the confirmed actual inevitably contains XvB win payouts. pct compares the
        # combined actual against the combined expectation.
        e = _summary_earnings(
            coeff_day=1e-8,
            xvb_day=0.001,
            confirmed={"enabled": True, "xmr_30d": 0.28, "partial": {"30d": False}},
        )
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), e, [], now=self.NOW)
        expected = 1e-8 * 8000.0 * 30 + 0.001 * 30
        assert s["xmr"]["available"] is True
        assert s["xmr"]["includes_xvb"] is True
        assert s["xmr"]["expected_30d"] == pytest.approx(expected)
        assert s["xmr"]["actual_30d"] == 0.28
        assert s["xmr"]["pct"] == round(0.28 / expected * 100)
        assert s["xmr"]["partial"] is False

    def test_combined_row_without_a_fresh_xvb_estimate_stays_p2pool_only(self, _metrics):
        # XvB on but no fresh published figure (#712) -> nothing is fabricated: expected stays
        # P2Pool-only and includes_xvb False (the client label drops "+ XvB"; the tooltip owns
        # the fact that win payouts still land in the actual). XvB disabled behaves the same.
        e = _summary_earnings(
            coeff_day=1e-8,
            confirmed={"enabled": True, "xmr_30d": 0.1, "partial": {}},
        )
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), e, [], now=self.NOW)
        assert s["xmr"]["includes_xvb"] is False
        assert s["xmr"]["expected_30d"] == pytest.approx(1e-8 * 8000.0 * 30)
        s = build_earnings_vs_actual(
            _metrics(p2pool_30d=8000.0, xvb_enabled=False),
            _summary_earnings(coeff_day=1e-8, xvb_day=0.001),
            [],
            now=self.NOW,
        )
        assert s["xmr"]["includes_xvb"] is False  # disabled XvB never folds its estimate in

    def test_negative_published_estimate_never_folds(self, _metrics):
        # xvb_day is upstream-published — a hostile/corrupt negative must not drag the combined
        # expectation toward (or past) zero while available stays True: it folds as 0, the label
        # stays P2Pool-only, and pct keeps a positive denominator.
        e = _summary_earnings(
            coeff_day=1e-8,
            xvb_day=-5.0,
            # In-range actual (~83% of expected): pct must survive the >999% withhold to prove
            # the denominator stayed positive.
            confirmed={"enabled": True, "xmr_30d": 0.002, "partial": {}},
        )
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), e, [], now=self.NOW)
        assert s["xmr"]["includes_xvb"] is False
        assert s["xmr"]["expected_30d"] == pytest.approx(1e-8 * 8000.0 * 30)
        assert s["xmr"]["pct"] is not None and s["xmr"]["pct"] > 0

    def test_pct_withheld_when_the_expectation_is_dust(self, _metrics):
        # A box idle for most of the window that still confirmed normal payouts: the ratio
        # against a near-zero expectation is a five-digit figure that reads as a bug (#992).
        # Past 999% the pct is withheld — the client tooltip explains — never capped to a
        # number that would still look like data.
        e = _summary_earnings(
            coeff_day=1e-8,
            confirmed={"enabled": True, "xmr_30d": 0.28, "partial": {}},
        )
        s = build_earnings_vs_actual(_metrics(p2pool_30d=1.0), e, [], now=self.NOW)
        assert s["xmr"]["available"] is True and s["xmr"]["enabled"] is True
        assert s["xmr"]["pct"] is None
        # At the boundary the figure still shows: 999% is large but legible.
        e = _summary_earnings(
            coeff_day=1e-8,
            confirmed={"enabled": True, "xmr_30d": 1e-8 * 8000.0 * 30 * 9.99, "partial": {}},
        )
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), e, [], now=self.NOW)
        assert s["xmr"]["pct"] == 999

    def test_xmr_row_degrades_honestly(self, _metrics):
        # Estimate unavailable (no network figures) -> not available, and no pct even with
        # confirmed payouts on; confirmation off -> actual/pct None, never a zero that would
        # read as "earned nothing".
        on = _summary_earnings(confirmed={"enabled": True, "xmr_30d": 0.5, "partial": {}})
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), on, [], now=self.NOW)
        assert s["xmr"]["available"] is False and s["xmr"]["pct"] is None
        off = _summary_earnings(coeff_day=1e-8)
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), off, [], now=self.NOW)
        assert s["xmr"]["enabled"] is False
        assert s["xmr"]["actual_30d"] is None and s["xmr"]["pct"] is None

    def test_xmr_partial_flag_rides_the_confirmed_window(self, _metrics):
        e = _summary_earnings(
            coeff_day=1e-8,
            confirmed={"enabled": True, "xmr_30d": 0.1, "partial": {"30d": True}},
        )
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), e, [], now=self.NOW)
        assert s["xmr"]["partial"] is True

    def test_tari_compares_block_counts_over_30d(self, _metrics):
        # Expected blocks = 30d-average hashrate × 30 days ÷ aux difficulty; actual = the
        # confirmed payout count (solo merge-mining: a payout IS a found block), XTM alongside.
        e = _summary_earnings(
            tari_confirmed={
                "enabled": True,
                "n_30d": 1,
                "xtm_30d": 12_345.0,
                "partial": {"30d": True},
            }
        )
        m = _metrics(p2pool_30d=10_000.0, tari_difficulty=4.0e12, tari_mining=True)
        s = build_earnings_vs_actual(m, e, [], now=self.NOW)
        assert s["tari"]["available"] is True
        assert s["tari"]["expected_blocks_30d"] == pytest.approx(10_000.0 * 30 * 86_400 / 4.0e12)
        assert s["tari"]["blocks_30d"] == 1
        assert s["tari"]["xtm_30d"] == 12_345.0
        assert s["tari"]["partial"] is True

    def test_tari_gates_on_mining_and_difficulty(self, _metrics):
        # A dead merge-mine channel (tari_mining False) or missing difficulty -> unavailable,
        # mirroring the calculator's gate, so no phantom expectation is shown.
        e = _summary_earnings()
        off = _metrics(p2pool_30d=10_000.0, tari_difficulty=4.0e12, tari_mining=False)
        assert build_earnings_vs_actual(off, e, [], now=self.NOW)["tari"]["available"] is False
        nodiff = _metrics(p2pool_30d=10_000.0, tari_difficulty=0.0, tari_mining=True)
        assert build_earnings_vs_actual(nodiff, e, [], now=self.NOW)["tari"]["available"] is False
        # Confirmation off -> counts None, not 0.
        s = build_earnings_vs_actual(
            _metrics(p2pool_30d=10_000.0, tari_difficulty=4.0e12, tari_mining=True),
            e,
            [],
            now=self.NOW,
        )
        assert s["tari"]["blocks_30d"] is None and s["tari"]["xtm_30d"] is None

    def test_xvb_counts_wins_in_the_trailing_30d_only(self, _metrics):
        wins = [
            {"ts": self.NOW - 40 * 86_400},  # outside the window
            {"ts": self.NOW - 10 * 86_400},
            {"ts": self.NOW - 86_400},
        ]
        s = build_earnings_vs_actual(
            _metrics(), _summary_earnings(xvb_day=0.004), wins, now=self.NOW
        )
        assert s["xvb"]["enabled"] is True
        assert s["xvb"]["wins_30d"] == 2
        assert s["xvb"]["last_win_ts"] == self.NOW - 86_400
        # No published_day here since #817 — the estimate lives in the combined row's expected.
        assert "published_day" not in s["xvb"]
        s = build_earnings_vs_actual(
            _metrics(xvb_enabled=False), _summary_earnings(), [], now=self.NOW
        )
        assert s["xvb"]["enabled"] is False and s["xvb"]["wins_30d"] == 0

    def test_rides_build_state_end_to_end(self, _data, _state_mgr, monkeypatch):
        # The summary must reach the top-level payload the client polls, built from the SAME
        # earnings dict the Earnings card receives — one build, so the two cannot disagree.
        monkeypatch.setattr(views.config, "PAYOUT_CONFIRM_ENABLED", False)
        monkeypatch.setattr(views.config, "TARI_PAYOUT_CONFIRM_ENABLED", False)
        st = views.build_state(_data(), _state_mgr(), "all")
        assert set(st["earnings_summary"]) == {"xmr", "tari", "xvb"}
        assert st["earnings_summary"]["xmr"]["enabled"] is False

    def test_frontend_fixture_matches_payload_shape_at_every_depth(self, tmp_path):
        # Drift guard (#808 post-mortem, deepened for #974): the frontend render tests run against
        # tests/frontend/fixtures/state.json, "a real build_state() payload". When the payload
        # grows a key without the fixture being regenerated, every component gated on that key
        # silently renders its empty state across the whole frontend suite and the visual harness.
        # Top-level pinning missed exactly that one level down (#880: nested keys whose parents
        # exist on both sides), so this compares full dotted key paths — the Python mirror of
        # CONFIG_KEY_PATHS_JQ in tests/integration/lib.sh. Shape only, never values: the fixture
        # is regenerated by running _gen_state.py (deterministic) to a temp file, so value tweaks
        # don't churn the test, and structural drift in either direction fails it.
        def _dotted_paths(node, prefix=""):
            # jq `paths` semantics: every path as a dotted string, array indices included.
            items = node.items() if isinstance(node, dict) else enumerate(node)
            for key, value in items:
                path = f"{prefix}.{key}" if prefix else str(key)
                yield path
                if isinstance(value, (dict, list)):
                    yield from _dotted_paths(value, path)

        fixture = Path(__file__).parents[2] / "frontend" / "fixtures" / "state.json"
        gen = fixture.with_name("_gen_state.py")
        out = tmp_path / "state.json"
        subprocess.run(  # noqa: S603 — fixed argv: our own interpreter + a repo-tracked script
            [sys.executable, str(gen), str(out)], check=True, capture_output=True
        )
        live = set(_dotted_paths(json.loads(out.read_text())))
        pinned = set(_dotted_paths(json.loads(fixture.read_text())))
        missing, removed = sorted(live - pinned), sorted(pinned - live)
        assert not missing and not removed, (
            f"frontend fixture is stale — regenerate with tests/frontend/fixtures/_gen_state.py "
            f"(paths missing from fixture: {missing}; paths gone from payload: {removed})"
        )
