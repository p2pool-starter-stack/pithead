import time
from unittest.mock import MagicMock

from mining_dashboard.service.data_helpers import (
    _XVB_WINNERS_SYNC_FAST_SEC,
    _XVB_WINNERS_SYNC_SEC,
    _xvb_winners_gate_sec,
)
from mining_dashboard.service.data_service import DataService

TIERS = {"donor": 1_000, "donor_whale": 100_000}
NOW = 1_000_000.0


def _gate(last_win_ts):
    return _xvb_winners_gate_sec(250_000, 250_000, TIERS, last_win_ts, NOW)


def test_a_win_dated_more_than_an_hour_ahead_keeps_the_baseline():
    assert _gate(NOW + 3601) == _XVB_WINNERS_SYNC_SEC
    assert _gate(NOW + 86_400 * 365) == _XVB_WINNERS_SYNC_SEC


def test_a_win_up_to_an_hour_ahead_or_in_the_fresh_window_is_fast():
    assert _gate(NOW + 3600) == _XVB_WINNERS_SYNC_FAST_SEC
    assert _gate(NOW) == _XVB_WINNERS_SYNC_FAST_SEC
    assert _gate(NOW - 5399) == _XVB_WINNERS_SYNC_FAST_SEC
    assert _gate(NOW - 5400) == _XVB_WINNERS_SYNC_SEC


async def _fetches_after(wins, wait):
    sm = MagicMock()
    sm.load_snapshot.return_value = None
    sm.get_xvb_stats.return_value = {"avg_1h": 250_000, "avg_24h": 250_000}
    sm.get_tiers.return_value = TIERS
    sm.get_raffle_wins.return_value = wins
    sm.add_raffle_wins.return_value = []
    svc = DataService(sm, MagicMock(), MagicMock())
    svc.xvb_client.get_recent_wins.return_value = {"wins": [], "round_stats": {}}
    await svc._sync_xvb_winners()
    svc._last_xvb_winners_sync -= wait
    await svc._sync_xvb_winners()
    return svc.xvb_client.get_recent_wins.call_count


async def test_a_far_future_row_does_not_hide_a_fresh_win():
    now = time.time()
    wins = [{"ts": now - 600}, {"ts": now + 86_400 * 365}]
    assert await _fetches_after(wins, _XVB_WINNERS_SYNC_FAST_SEC + 1) == 2


async def test_a_far_future_row_alone_keeps_the_baseline():
    wins = [{"ts": time.time() + 86_400 * 365}]
    assert await _fetches_after(wins, _XVB_WINNERS_SYNC_FAST_SEC + 1) == 1
