# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestBlockEdges:
    """#336: block-found / payout-found off p2pool's cumulative totalBlocksFound counter."""

    def test_first_observation_seeds_silently(self):
        # A dashboard restart must not replay the last block.
        svc = _svc()
        assert _ev(svc, blocks_found_total=7, block_height=3_000_000) == []
        assert _ev(svc, blocks_found_total=7, block_height=3_000_000) == []  # steady -> quiet

    def test_block_without_share_alerts_block_only(self):
        svc = _svc()
        _ev(svc, blocks_found_total=7)  # seed
        alerts = _ev(svc, blocks_found_total=8, block_height=3_000_123, shares_in_window=0)
        assert _keys(alerts) == [AlertService.EVT_BLOCK_FOUND]
        assert "3,000,123" in alerts[0][1]

    def test_block_with_share_also_alerts_payout(self):
        svc = _svc()
        _ev(svc, blocks_found_total=7)  # seed
        alerts = _ev(svc, blocks_found_total=8, block_height=3_000_123, shares_in_window=3)
        assert _keys(alerts) == [AlertService.EVT_BLOCK_FOUND, AlertService.EVT_PAYOUT_FOUND]
        assert "3 PPLNS share(s)" in alerts[1][1]

    def test_counter_backwards_rebaselines_silently(self):
        # p2pool restart: the counter resets, the next observation seeds the new baseline
        # silently (two-step), and the next real find from there still fires.
        svc = _svc()
        _ev(svc, blocks_found_total=7)  # seed
        assert _ev(svc, blocks_found_total=0) == []  # backwards -> arm rebaseline
        assert _ev(svc, blocks_found_total=0) == []  # next observation seeds silently
        assert _keys(_ev(svc, blocks_found_total=1, block_height=3_000_200)) == [
            AlertService.EVT_BLOCK_FOUND
        ]

    def test_transient_stats_blank_does_not_fire(self):
        # A partially-written stats file reads 0 for one poll, then restores the real counter.
        # The 7→0→7 round trip must stay silent — the restored 7 is not "found 7 blocks".
        svc = _svc()
        _ev(svc, blocks_found_total=7)  # seed
        assert _ev(svc, blocks_found_total=0) == []  # blank -> arm rebaseline
        assert _ev(svc, blocks_found_total=7) == []  # restore seeds silently
        # Normal edge behavior resumes: the next genuine find fires once.
        assert _keys(_ev(svc, blocks_found_total=8, block_height=3_000_400)) == [
            AlertService.EVT_BLOCK_FOUND
        ]

    def test_burst_alerts_once_with_the_count(self):
        svc = _svc()
        _ev(svc, blocks_found_total=7)  # seed
        alerts = _ev(svc, blocks_found_total=10, block_height=3_000_300)
        assert _keys(alerts) == [AlertService.EVT_BLOCK_FOUND]
        assert "3 Monero blocks" in alerts[0][1]

    def test_good_news_is_not_an_incident(self):
        svc = _svc()
        _ev(svc, blocks_found_total=7)
        _ev(svc, blocks_found_total=8, shares_in_window=2)
        assert svc.drain_incidents() == {}
