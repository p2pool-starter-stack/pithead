"""XvB tier-table presentation extracted from :mod:`xvb_views`."""

from mining_dashboard.config.config import XVB_MAX_DONATION_FRACTION
from mining_dashboard.helper.utils import get_tier_info, xvb_stats_are_stale
from mining_dashboard.web.views.xvb_views import (
    _XVB_SIDECHAIN_NOTE,
    _XVB_TIER_NOTE,
    XVB_PUBLISHED_REWARD_FALLBACK,
    XVB_PUBLISHED_REWARD_FALLBACK_DATE,
    XVB_REALIZATION_PRIOR,
)


def build_xvb_calc(metrics, state_mgr, realization=None):
    """XvB tier/raffle calculator inputs for the Advanced view (Issue #118).

    Same pattern as ``build_earnings``'s ``coeff_day``: the server publishes the tier table and
    the sustainability rule once (single source of truth — ``state_mgr.get_tiers()``, so a
    ``TIER_CONFIG`` override flows through, plus ``XVB_MAX_DONATION_FRACTION``), and the client
    does the what-if math (``computeXvbTier`` in ``logic.mjs``, a transcription of
    ``resolve_target_threshold``'s auto rule). Current/target tier state comes straight off
    ``Metrics`` — no tier math is re-derived here.

    The draw is random among qualifiers, but the winners file publishes the qualifier count per
    round (#872), so each tier carries its measurable draw context: ``win_odds_day`` (that round
    type's frequency ÷ its average qualifiers — per-round-type, unlike the earnings card's
    cumulative forecast) and ``players_avg`` (which also makes a single-qualifier artifact like
    Mega's self-evident). ``realized_reward_year`` scales the published figure by this wallet's
    measured win realization (``realization``, from ``xvb_realization``) — None when unmeasured,
    so the client falls back to the study band; face value shows only in its own column.

    Published with XvB DISABLED too (#938): the table is the enable/don't-enable decision aid, so
    hiding it behind the flag defeated its purpose. Everything here is computable from local
    config plus the cached public feeds; disabling XvB stops the fetches (the egress rule, #726).
    The reward columns still light up on a box that is DISABLED — never enabled, or turned off
    after its cache aged out (#1214): when nothing live/cached is usable AND ``metrics.xvb_enabled``
    is False, they fall back to ``XVB_PUBLISHED_REWARD_FALLBACK``, a static, dated, labelled
    snapshot of XvB's own published table (never a live fetch, so the egress rule is untouched) —
    ``estimates_source``/``estimates_published_date`` tell the client which one it got. The
    fallback deliberately does NOT fire for an ENABLED-but-stale box (e.g. a transient fetch
    failure such as a bot-challenge): that box's live estimate is momentarily unavailable, not
    "off", so it keeps the honest pre-existing degradation instead — ``estimates_source`` reads
    "none" and the client shows the same "estimate unavailable" text it always has. The odds
    column has no fallback at all, disabled or not: qualifier counts are live competitive data
    with no stable published table to vendor, so it stays honestly empty until XvB runs and the
    winners feed populates the cache. The live-credit context goes quiet on its own: ``build_state``
    computes ``realization`` only while enabled, and ``Metrics`` reports current/target tier as
    "Disabled" — the client keys every live-donation surface (and the current/target cards here)
    off ``enabled``."""
    tiers = state_mgr.get_tiers()
    round_state = state_mgr.get_xvb_round_stats()
    round_types = (
        {}
        if xvb_stats_are_stale(round_state)
        else ((round_state.get("stats") or {}).get("types") or {})
    )
    span_days = ((round_state.get("stats") or {}).get("span_days") or 0.0) if round_types else 0.0

    def _odds_day(key):
        agg = round_types.get(key)
        if not agg or span_days <= 0 or agg.get("players_avg", 0) <= 0:
            return None
        return (agg["rounds"] / span_days) / agg["players_avg"]

    # XvB's published per-tier expected reward (XMR/year), fetched over Tor and cached (#118). The
    # tier KEY is exactly the round-type in the file (donor / donor_vip / donor_whale / donor_mega),
    # so a tier maps to its estimate by key. A stale or empty cache degrades to None per tier +
    # estimates_available False (reusing the stats staleness rule so the two never disagree, #311)
    # — ``_face_value`` below then tries the vendored fallback before giving up.
    est_state = state_mgr.get_xvb_reward_estimates()
    estimates = (est_state or {}).get("estimates") or {}
    estimates_stale = xvb_stats_are_stale(est_state)
    estimates_available = bool(estimates) and not estimates_stale
    # #1214: one static fallback figure per tier, tried only when the box is DISABLED (never
    # enabled, or turned off after its cache aged out) — an enabled box with a merely-stale or
    # not-yet-populated cache (a transient fetch failure, e.g. a bot-challenge) is NOT "off"; it
    # keeps the honest pre-existing "estimate unavailable" degradation instead of a fallback that
    # would falsely read as "XvB is off, using its last published table". Only tried for tiers the
    # archived table actually names — a custom TIER_CONFIG round-type it doesn't recognise just
    # stays None, same as before this fix.
    fallback_eligible = not metrics.xvb_enabled
    fallback_used = False

    def _face_value(key):
        """XvB's own face figure for a tier — live estimate first, vendored fallback second.

        ``realized_reward_year`` deliberately does NOT use this: mixing THIS wallet's own
        measured delivery factor with a dated, generic fallback would overstate precision the
        wallet has no basis for, and ``realization`` is only ever non-None while XvB is enabled
        (``build_state``), when a live estimate is normally available anyway. It keeps requiring
        a live, fresh figure, same as before this fix."""
        nonlocal fallback_used
        if estimates_available and key in estimates:
            return float(estimates[key])
        if not estimates_available and fallback_eligible and key in XVB_PUBLISHED_REWARD_FALLBACK:
            fallback_used = True
            return XVB_PUBLISHED_REWARD_FALLBACK[key]
        return None

    tier_rows = []
    for key, t in tiers.items():
        if t <= 0:
            continue
        face = _face_value(key)
        live_face = float(estimates[key]) if estimates_available and key in estimates else None
        tier_rows.append(
            {
                "name": get_tier_info(t, tiers)[0],
                "threshold": float(t),
                "expected_reward_year": face,
                # Published figure × measured realization (#872) — the net the panel can
                # honestly act on. None until enough wins measure the factor; LIVE face value
                # only (see ``_face_value``'s docstring) — a stale/fallback figure can't be
                # "realized" against.
                "realized_reward_year": (
                    live_face * realization[0] if live_face is not None and realization else None
                ),
                # Unmeasured boxes still get a calculable band (#872): the published figure
                # (live or vendored fallback) scaled by the measured realization PRIOR below.
                # None once a local measurement exists (realized_reward_year supersedes it) or no
                # face value is available at all — the two never show together.
                "assumed_reward_year_range": (
                    [face * XVB_REALIZATION_PRIOR[0], face * XVB_REALIZATION_PRIOR[1]]
                    if face is not None and not realization
                    else None
                ),
                "win_odds_day": _odds_day(key),
                "players_avg": (round_types.get(key) or {}).get("players_avg"),
            }
        )
    return {
        "enabled": metrics.xvb_enabled,
        # Ascending tier table for the client's what-if; names via get_tier_info so they read
        # exactly like the tier strings everywhere else (threshold already embedded in the name).
        "tiers": sorted(tier_rows, key=lambda entry: entry["threshold"]),
        "estimates_available": estimates_available,
        "estimates_stale": estimates_stale,
        # #1214: "live" when a fresh fetch backs the reward columns, "published" when the vendored
        # fallback filled them instead (with the date it was archived, so the client can label how
        # old it is), "none" when neither had anything for any tier.
        "estimates_source": "live"
        if estimates_available
        else ("published" if fallback_used else "none"),
        "estimates_published_date": XVB_PUBLISHED_REWARD_FALLBACK_DATE if fallback_used else None,
        # Measurement context for the realized figures: the factor and its sample size, or None
        # while unmeasured (the client then labels the published number face value).
        "realization_pct": round(realization[0] * 100) if realization else None,
        "realization_wins": realization[1] if realization else None,
        "max_fraction": XVB_MAX_DONATION_FRACTION,  # donation headroom rule (sustainability)
        "current_tier": metrics.current_tier,
        "target_tier": metrics.target_tier,
        "target_threshold": metrics.target_threshold,
        "sustainable": metrics.target_sustainable,
        "note": _XVB_TIER_NOTE,
        # #33 mode context, display-only: off the Main sidechain a pool switch costs your PPLNS
        # shares — and with them XvB win collectability. None on Main (nothing to warn about).
        "mode_note": _XVB_SIDECHAIN_NOTE if metrics.pool_type != "Main" else None,
    }
