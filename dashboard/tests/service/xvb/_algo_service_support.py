# ruff: noqa: F401
import asyncio
import time
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from mining_dashboard.config.config import (
    XVB_STALE_DECAY_AFTER_S,
    XVB_STATS_STALE_AFTER_S,
    XVB_SWITCH_OVERHEAD_MS,
    XVB_TIME_ALGO_MS,
)

RECENT_SHARES = [{"ts": 10**12}]  # far-future ts -> always within window

P2P_MAIN = {"type": "Main"}

POOL_STATS = {"pplns_window": 2160}  # no difficulty -> flat reserve

POOL_STATS_DIFF = {"pplns_window": 2160, "difficulty": 120_000_000}


def _fresh_ts():
    """A `last_update` that reads as a just-landed XvB fetch (not stale)."""
    return time.time()


def _stale_ts():
    """A `last_update` old enough that the fetch is considered stale (#311)."""
    return time.time() - (XVB_STATS_STALE_AFTER_S + 60)


def _decay_ts():
    """A `last_update` old enough to be past the prolonged-staleness decay grace, not just
    the short hold grace — the fail-safe should bleed the donation fraction toward 0."""
    return time.time() - (XVB_STALE_DECAY_AFTER_S + 60)


def _split_ms(decision):
    mode, dur = decision
    return XVB_TIME_ALGO_MS if mode == "XVB" else dur


__all__ = [name for name in globals() if not name.startswith("__")]
