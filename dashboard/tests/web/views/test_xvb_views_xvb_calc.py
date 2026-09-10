# ruff: noqa: F403, F405
from tests.web.views._xvb_views_support import *  # noqa: F403


class TestXvbCalc:
    # Includes a zero-threshold entry to prove it's filtered out of the published table.
    _TIERS = {
        "donor_mega": 1_000_000,
        "donor_whale": 100_000,
        "donor_vip": 10_000,
        "donor": 1_000,
        "off": 0,
    }

    # XvB's published per-tier expected rewards, keyed by round-type == tier key (#118).
    _ESTIMATES = {"donor": 0.06, "donor_vip": 0.81, "donor_whale": 6.17, "donor_mega": 56.9}

    # All-rounds aggregate from the winners file (#872): frequencies + qualifier counts over
    # a one-week span, shaped like parse_round_stats' output.
    _ROUND_STATS = {
        "types": {
            "donor": {"rounds": 7, "players_avg": 70.0},
            "donor_vip": {"rounds": 28, "players_avg": 28.0},
            "donor_whale": {"rounds": 56, "players_avg": 8.0},
            "donor_mega": {"rounds": 63, "players_avg": 1.0},
        },
        "span_days": 7.0,
    }

    def _sm(self, estimates=None, last_update=None, round_stats=None, round_ts=None):
        sm = MagicMock()
        sm.get_tiers.return_value = self._TIERS
        est = self._ESTIMATES if estimates is None else estimates
        ts = time.time() if last_update is None else last_update
        sm.get_xvb_reward_estimates.return_value = {"estimates": est, "last_update": ts}
        stats = self._ROUND_STATS if round_stats is None else round_stats
        sm.get_xvb_round_stats.return_value = {
            "stats": stats,
            "last_update": time.time() if round_ts is None else round_ts,
        }
        return sm

    def test_disabled_still_publishes_the_decision_table(self, _metrics):
        # #938: XvB off no longer collapses the payload to the bare flag — the table is the
        # enable/don't-enable decision aid, so the tiers, draw odds, and prior band publish
        # either way (from local config + the cached feeds; the flag stops the fetches, so a
        # never-enabled box degrades through the same staleness rules as always). enabled=False
        # still rides along: the client's live-donation surfaces key off it.
        out = build_xvb_calc(
            _metrics(xvb_enabled=False, current_tier="Disabled", target_tier="Disabled"),
            self._sm(),
        )
        assert out["enabled"] is False
        assert [t["threshold"] for t in out["tiers"]] == [1_000, 10_000, 100_000, 1_000_000]
        whale = next(t for t in out["tiers"] if t["threshold"] == 100_000)
        assert whale["win_odds_day"] == pytest.approx((56 / 7.0) / 8.0)
        lo, hi = xvb_views.XVB_REALIZATION_PRIOR
        assert whale["assumed_reward_year_range"] == pytest.approx([6.17 * lo, 6.17 * hi])
        assert out["max_fraction"] == xvb_views.XVB_MAX_DONATION_FRACTION
        # Live-credit context passes through what Metrics reports on a disabled box; realization
        # is never computed while off (build_state's gate), so the measured fields stay None.
        assert out["current_tier"] == "Disabled"
        assert out["realization_pct"] is None

    def test_tier_table_sorted_ascending_and_zero_thresholds_dropped(self, _metrics):
        out = build_xvb_calc(_metrics(), self._sm())
        assert [t["threshold"] for t in out["tiers"]] == [1_000, 10_000, 100_000, 1_000_000]
        # Names come from get_tier_info, threshold already embedded — same string as everywhere.
        assert out["tiers"][1]["name"] == "Vip (10.00 kH/s+)"

    def test_mirrors_metrics_and_config(self, _metrics):
        # Current/target state is passed straight through from Metrics — no tier math re-derived
        # here — and max_fraction is the configured sustainability headroom rule.
        m = _metrics(
            current_tier="Donor (1.00 kH/s+)",
            target_tier="Vip (10.00 kH/s+)",
            target_threshold=10_000.0,
            target_sustainable=False,
        )
        out = build_xvb_calc(m, self._sm())
        assert out["enabled"] is True
        assert out["current_tier"] == "Donor (1.00 kH/s+)"
        assert out["target_tier"] == "Vip (10.00 kH/s+)"
        assert out["target_threshold"] == 10_000.0
        assert out["sustainable"] is False
        assert out["max_fraction"] == xvb_views.XVB_MAX_DONATION_FRACTION
        # The labelling the issue demands: tier = raffle status, never a payout.
        assert "not an XMR payout" in out["note"]

    def test_sidechain_mode_note_only_off_main(self, _metrics):
        # #33 context: off the Main sidechain, a pool switch resets PPLNS shares (and with them
        # XvB win collectability) — display-only text, absent on Main.
        assert build_xvb_calc(_metrics(pool_type="Main"), self._sm())["mode_note"] is None
        note = build_xvb_calc(_metrics(pool_type="Mini"), self._sm())["mode_note"]
        assert "PPLNS" in note

    def test_fresh_estimates_expose_per_tier_expected_reward(self, _metrics):
        # #118: each tier carries XvB's own published XMR/year figure, mapped by the tier key
        # (== round-type), and the estimates_available flag is set on a fresh fetch.
        out = build_xvb_calc(_metrics(), self._sm())
        assert out["estimates_available"] is True
        assert out["estimates_stale"] is False
        by_threshold = {t["threshold"]: t["expected_reward_year"] for t in out["tiers"]}
        assert by_threshold[1_000] == 0.06  # donor
        assert by_threshold[10_000] == 0.81  # donor_vip
        assert by_threshold[100_000] == 6.17  # donor_whale
        assert by_threshold[1_000_000] == 56.9  # donor_mega

    def test_enabled_stale_estimates_do_not_use_the_fallback(self, _metrics):
        # #1214 regression: an ENABLED box whose fetch is merely failing right now (a transient
        # bot-challenge, a network blip — the sync loop writes only on success) must NOT get the
        # vendored fallback. That box isn't "off"; claiming "published, not live because XvB is
        # off" would be a straight lie. It keeps exactly the pre-#1214 honest degradation: no
        # per-tier number implied fresh, estimates_available False, estimates_source "none".
        sm = self._sm(last_update=time.time() - XVB_STATS_STALE_AFTER_S - 1)
        out = build_xvb_calc(_metrics(xvb_enabled=True), sm)
        assert out["estimates_available"] is False
        assert out["estimates_stale"] is True
        assert out["estimates_source"] == "none"
        assert out["estimates_published_date"] is None
        assert all(t["expected_reward_year"] is None for t in out["tiers"])
        assert all(t["assumed_reward_year_range"] is None for t in out["tiers"])

    def test_disabled_stale_falls_back_to_the_published_table(self, _metrics):
        # A DISABLED box whose cache aged out while off — "just-disabled" in the issue's terms —
        # gets the vendored fallback: no per-tier number implied FRESH (estimates_available stays
        # False), but expected_reward_year fills in from XvB's own last-published table (never a
        # live number, and labelled as such via estimates_source).
        sm = self._sm(last_update=time.time() - XVB_STATS_STALE_AFTER_S - 1)
        out = build_xvb_calc(_metrics(xvb_enabled=False), sm)
        assert out["estimates_available"] is False
        assert out["estimates_stale"] is True
        assert out["estimates_source"] == "published"
        assert out["estimates_published_date"] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK_DATE
        by_threshold = {t["threshold"]: t["expected_reward_year"] for t in out["tiers"]}
        assert by_threshold[1_000] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor"]
        assert by_threshold[100_000] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor_whale"]

    def test_disabled_never_fetched_falls_back_to_the_published_table(self, _metrics):
        # #1214's actual bug report: a box that has NEVER enabled XvB has no cache at all (never
        # fetched, not merely stale). Same fallback, same labelling.
        sm = self._sm(estimates={}, last_update=0.0)
        out = build_xvb_calc(_metrics(xvb_enabled=False), sm)
        assert out["estimates_available"] is False
        assert out["estimates_stale"] is False
        assert out["estimates_source"] == "published"
        by_threshold = {t["threshold"]: t["expected_reward_year"] for t in out["tiers"]}
        assert by_threshold[1_000] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor"]
        assert by_threshold[10_000] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor_vip"]
        assert by_threshold[100_000] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor_whale"]
        assert by_threshold[1_000_000] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor_mega"]

    @pytest.mark.skipif(
        _XVB_ARCHIVE is None or not _XVB_ARCHIVE.exists(),
        reason="the delivery-study archive lives outside the dashboard image's build context; "
        "this parity guard runs in the checkout-based dashboard CI job, which fails loudly "
        "if the fallback and the archive ever disagree",
    )
    def test_fallback_values_match_the_archived_source_files_player_rows(self):
        # #1214 guard: the vendored fallback must be the PER-PLAYER row XvB publishes, exactly
        # what the live parser would extract — never the pool-total row just above it (that
        # figure is the whole round's payout, not one qualifier's share, and is 7-70x larger).
        # Parses the archived source with the real live parser
        # (mining_dashboard.client.xvb_client.parse_reward_estimates, the exact regex a live
        # fetch uses) so a future re-vendor from the wrong column fails this test immediately
        # instead of silently drifting from what a live fetch would ever show.
        from mining_dashboard.client.xvb_client import DONOR_ROUND_TYPES, parse_reward_estimates

        parsed = parse_reward_estimates(_XVB_ARCHIVE.read_text())
        assert set(parsed) == set(DONOR_ROUND_TYPES)  # the archive still names all four tiers
        assert xvb_views.XVB_PUBLISHED_REWARD_FALLBACK == parsed

    def test_round_stats_expose_per_tier_draw_odds(self, _metrics):
        # #872: the winners file's players column makes the draw knowable — each tier carries its
        # OWN round type's frequency ÷ qualifiers (the earnings card's forecast, by contrast,
        # sums the lower tiers a qualifier also plays in).
        out = build_xvb_calc(_metrics(), self._sm())
        by_threshold = {t["threshold"]: t for t in out["tiers"]}
        assert by_threshold[100_000]["win_odds_day"] == pytest.approx((56 / 7.0) / 8.0)
        assert by_threshold[100_000]["players_avg"] == 8.0
        # The single-qualifier artifact is self-evident: one Mega player, one win per draw.
        assert by_threshold[1_000_000]["players_avg"] == 1.0

    def test_stale_or_missing_round_stats_null_the_odds(self, _metrics):
        stale = self._sm(round_ts=time.time() - XVB_STATS_STALE_AFTER_S - 1)
        assert all(t["win_odds_day"] is None for t in build_xvb_calc(_metrics(), stale)["tiers"])
        empty = self._sm(round_stats={"types": {}, "span_days": 0.0}, round_ts=0.0)
        assert all(t["win_odds_day"] is None for t in build_xvb_calc(_metrics(), empty)["tiers"])

    def test_realization_scales_published_rewards_into_realized(self, _metrics):
        # #872: with a measured factor, every tier carries published × factor — the figure whose
        # net can honestly be acted on — plus the factor and its sample size for the label.
        out = build_xvb_calc(_metrics(), self._sm(), realization=(0.19, 15))
        by_threshold = {t["threshold"]: t for t in out["tiers"]}
        assert by_threshold[100_000]["realized_reward_year"] == pytest.approx(6.17 * 0.19)
        assert out["realization_pct"] == 19
        assert out["realization_wins"] == 15

    def test_unmeasured_boxes_get_the_prior_band_measured_boxes_do_not(self, _metrics):
        # #872: no local measurement -> published × the measured prior band, so "should I enable
        # this" is answerable everywhere. A measured factor supersedes it (never both).
        out = build_xvb_calc(_metrics(), self._sm())
        whale = next(t for t in out["tiers"] if t["threshold"] == 100_000)
        lo, hi = xvb_views.XVB_REALIZATION_PRIOR
        assert whale["assumed_reward_year_range"] == pytest.approx([6.17 * lo, 6.17 * hi])
        out = build_xvb_calc(_metrics(), self._sm(), realization=(0.19, 15))
        assert all(t["assumed_reward_year_range"] is None for t in out["tiers"])
        # A measured factor still wins even on a DISABLED, stale box where #1214's vendored
        # fallback is otherwise eligible — "yours" always supersedes the band, fallback or not.
        stale = self._sm(last_update=time.time() - XVB_STATS_STALE_AFTER_S - 1)
        out = build_xvb_calc(_metrics(xvb_enabled=False), stale, realization=(0.19, 15))
        assert all(t["assumed_reward_year_range"] is None for t in out["tiers"])
        # Same DISABLED, stale box with NO measured factor: #1214's fallback fills the band from
        # the published face value instead of leaving it null — the whole point of the fallback.
        # (An ENABLED, stale box must NOT do this — see test_enabled_stale_estimates_do_not_use_
        # the_fallback — the fallback is gated on the box being off, not merely stale.)
        out = build_xvb_calc(_metrics(xvb_enabled=False), stale)
        whale = next(t for t in out["tiers"] if t["threshold"] == 100_000)
        face = xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor_whale"]
        assert whale["assumed_reward_year_range"] == pytest.approx([face * lo, face * hi])

    def test_no_realization_leaves_realized_none(self, _metrics):
        # Unmeasured (too few wins / payout confirmation off): realized stays None so the client
        # falls back to face value AND says so — never a fabricated factor.
        out = build_xvb_calc(_metrics(), self._sm())
        assert all(t["realized_reward_year"] is None for t in out["tiers"])
        assert out["realization_pct"] is None
        # Stale estimates null realized too — a factor cannot resurrect a stale face value.
        sm = self._sm(last_update=time.time() - XVB_STATS_STALE_AFTER_S - 1)
        out = build_xvb_calc(_metrics(), sm, realization=(0.5, 9))
        assert all(t["realized_reward_year"] is None for t in out["tiers"])

    def test_empty_estimates_available_false_no_crash(self, _metrics):
        # Never fetched / unparseable cache on an ENABLED box (e.g. mid cold-start right after
        # enabling, or persistently-failing fetches — never "off"): available False, not "stale"
        # (last_update 0), and #1214's fallback must NOT fire here — same gate as the stale case,
        # see test_enabled_stale_estimates_do_not_use_the_fallback. The never-enabled-XvB box the
        # issue is actually about is test_disabled_never_fetched_falls_back_to_the_published_table.
        sm = self._sm(estimates={}, last_update=0.0)
        out = build_xvb_calc(_metrics(xvb_enabled=True), sm)
        assert out["estimates_available"] is False
        assert out["estimates_stale"] is False
        assert out["estimates_source"] == "none"
        assert all(t["expected_reward_year"] is None for t in out["tiers"])

    def test_fallback_never_backs_realized_reward_year(self, _metrics):
        # #1214: THIS wallet's own measured delivery factor must never be applied to a dated,
        # generic fallback figure — that would overstate precision the wallet has no basis for.
        # realized_reward_year keeps requiring a LIVE, fresh estimate even when realization is
        # (unusually) supplied alongside a disabled box's empty cache.
        sm = self._sm(estimates={}, last_update=0.0)
        out = build_xvb_calc(_metrics(xvb_enabled=False), sm, realization=(0.5, 9))
        assert all(t["realized_reward_year"] is None for t in out["tiers"])
        # expected_reward_year still gets the fallback — only realized_reward_year is withheld.
        assert any(t["expected_reward_year"] is not None for t in out["tiers"])

    def test_fallback_skips_tiers_the_published_table_does_not_name(self, _metrics):
        # A custom TIER_CONFIG round-type the archived table never named degrades to None, same
        # as before this fix — the fallback is a fixed vendored table, never invented per key.
        sm = self._sm(estimates={}, last_update=0.0)
        sm.get_tiers.return_value = {"donor": 1_000, "custom_tier": 5_000}
        out = build_xvb_calc(_metrics(xvb_enabled=False), sm)
        by_threshold = {t["threshold"]: t["expected_reward_year"] for t in out["tiers"]}
        assert by_threshold[1_000] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor"]
        assert by_threshold[5_000] is None

    def test_live_estimates_report_source_live_no_fallback_date(self, _metrics):
        # A fresh live fetch must be labelled "live", never "published" — the two must never be
        # ambiguous to the client, which uses this to decide the disabled-note wording.
        out = build_xvb_calc(_metrics(), self._sm())
        assert out["estimates_source"] == "live"
        assert out["estimates_published_date"] is None

    def test_never_fetched_and_fallback_missing_reports_source_none(self, _metrics):
        # A DISABLED box whose future TIER_CONFIG names nothing the fallback recognises must
        # still report "none" rather than falsely claiming "published" — isolates the "fallback
        # dict has no matching key" case from the enabled/disabled gate (test above).
        sm = self._sm(estimates={}, last_update=0.0)
        sm.get_tiers.return_value = {"custom_tier": 5_000}
        out = build_xvb_calc(_metrics(xvb_enabled=False), sm)
        assert out["estimates_source"] == "none"
        assert out["estimates_published_date"] is None

    def test_disabled_path_never_touches_the_network_layer(self, _metrics):
        # #163's no-egress-when-disabled contract, at this tier: filling the decision table's
        # reward columns from #1214's vendored fallback must never make an outbound HTTP call —
        # build_xvb_calc only reads state_mgr (local) and the static XVB_PUBLISHED_REWARD_FALLBACK
        # dict. Patches BOTH the chokepoint every real XvB fetch goes through
        # (mining_dashboard.helper.http.bounded_get) AND requests' own low-level entry point
        # (requests.sessions.Session.request, what requests.get ultimately calls), so a
        # regression that wires an on-demand fetch into this path — through the shared helper or
        # straight through requests — fails this test immediately rather than passing quietly.
        import requests

        import mining_dashboard.helper.http as http_mod

        def _dial(*a, **k):
            raise AssertionError("build_xvb_calc must never dial out while XvB is disabled")

        sm = self._sm(estimates={}, last_update=0.0)
        with (
            patch.object(http_mod, "bounded_get", side_effect=_dial),
            patch.object(requests.sessions.Session, "request", side_effect=_dial),
        ):
            out = build_xvb_calc(_metrics(xvb_enabled=False), sm)
        # And the fallback did its job — the dashes are gone, not just "no crash".
        assert out["estimates_source"] == "published"
        assert all(t["expected_reward_year"] is not None for t in out["tiers"])

    # --- current-tier reward folded into net profit (#712) ---------------------------

    def test_reward_day_is_current_tier_estimate_over_365(self, _metrics):
        # Base metrics credit min(xvb_1h=2100, xvb_24h=2300)=2100 → the donor tier (>=1000, <10k);
        # its published 0.06 XMR/year becomes 0.06/365 XMR/day. The estimate feeds est.xvbDay.
        out = xvb_current_tier_reward_day(_metrics(), self._sm())
        assert out == pytest.approx(0.06 / 365)

    def test_reward_day_uses_lower_of_1h_24h_not_the_higher(self, _metrics):
        # The current tier is the LOWER of the two credited averages (not target): a 1h dip to the
        # donor tier holds there even while 24h still clears whale — the honest "what you hold now".
        out = xvb_current_tier_reward_day(_metrics(xvb_1h=2100, xvb_24h=200_000), self._sm())
        assert out == pytest.approx(0.06 / 365)  # donor, not whale (6.17)

    def test_reward_day_maps_higher_tier_to_its_own_estimate(self, _metrics):
        # min(150k, 200k)=150k clears donor_whale (100k) → its 6.17/year, proving the tier→key→
        # estimate mapping picks the right round-type, not always the lowest.
        out = xvb_current_tier_reward_day(_metrics(xvb_1h=150_000, xvb_24h=200_000), self._sm())
        assert out == pytest.approx(6.17 / 365)

    def test_reward_day_none_when_xvb_disabled(self, _metrics):
        assert xvb_current_tier_reward_day(_metrics(xvb_enabled=False), self._sm()) is None

    def test_reward_day_none_below_lowest_donor_tier(self, _metrics):
        # min(500, 800)=500 < the 1000 donor threshold → "None" tier, nothing published to credit.
        assert xvb_current_tier_reward_day(_metrics(xvb_1h=500, xvb_24h=800), self._sm()) is None

    def test_reward_day_none_when_estimate_stale(self, _metrics):
        # Same staleness gate as the XvB card (#311): never surface a frozen number implied fresh.
        sm = self._sm(last_update=time.time() - XVB_STATS_STALE_AFTER_S - 1)
        assert xvb_current_tier_reward_day(_metrics(), sm) is None

    def test_reward_day_none_when_estimate_absent(self, _metrics):
        # Held a tier, but XvB never published a figure for it → None, never a fabricated 0.
        sm = self._sm(estimates={"donor_vip": 0.81}, last_update=time.time())
        assert xvb_current_tier_reward_day(_metrics(), sm) is None
