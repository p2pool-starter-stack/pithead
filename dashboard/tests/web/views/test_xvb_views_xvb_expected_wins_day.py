# ruff: noqa: F403, F405
from tests.web.views._xvb_views_support import *  # noqa: F403


class TestXvbExpectedWinsDay:
    def test_sums_every_donor_round_type_the_held_tier_qualifies_for(self):
        # A whale qualifier also plays the vip and donor rounds beneath it: the forecast is the
        # sum of each round type's frequency ÷ its qualifier count, not the whale rounds alone.
        out = xvb_expected_wins_day(_round_state(), "donor_whale", _WINS_TIERS)
        assert out == pytest.approx((56 / 7.0) / 8.0 + (28 / 7.0) / 28.0 + (7 / 7.0) / 70.0)
        # A donor-tier fleet only plays the donor rounds.
        assert xvb_expected_wins_day(_round_state(), "donor", _WINS_TIERS) == pytest.approx(
            (7 / 7.0) / 70.0
        )

    def test_missing_stale_or_empty_aggregate_yields_none(self):
        assert xvb_expected_wins_day(None, "donor_whale", _WINS_TIERS) is None
        assert xvb_expected_wins_day(_round_state(stale=True), "donor_whale", _WINS_TIERS) is None
        empty = {"stats": {"types": {}, "span_days": 0.0}, "last_update": time.time()}
        assert xvb_expected_wins_day(empty, "donor_whale", _WINS_TIERS) is None
        assert xvb_expected_wins_day(_round_state(), None, _WINS_TIERS) is None
