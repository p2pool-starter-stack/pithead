# ruff: noqa: F401
"""Unit tests for the XvB/earnings/badges cluster (mining_dashboard/web/views/xvb_views.py).

Moved out of tests/web/views/test_views.py with the cluster itself (#1105). The test bodies are
verbatim; the only edits are module-alias reads that follow their targets from ``views`` to
``xvb_views``.

The shared builders — ``_SYNC_DONE``/``_BASE`` and the ``_metrics``, ``_sync``, ``_hashrate``,
``_state_mgr`` and ``_data`` factories — are pytest fixtures in ``tests/web/conftest.py`` as of
#1459. Each test that needs one takes it as a parameter; the call itself reads as it always did.
What is deliberately NOT shared, and why, is written in that file.
"""

import json
import subprocess
import sys
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

import mining_dashboard.service.metrics as service_metrics
import mining_dashboard.web.views.views as views
import mining_dashboard.web.views.xvb_views as xvb_views
from mining_dashboard.config.config import XVB_STATS_STALE_AFTER_S
from mining_dashboard.web.views.xvb_views import (
    build_badges,
    build_earnings,
    build_earnings_vs_actual,
    build_xvb_calc,
    recent_wallet_change,
    xvb_current_tier_reward_day,
    xvb_expected_wins_day,
    xvb_realization,
    xvb_tempered_day,
)


def _xvb_archive():
    # In a checkout the repo root is three levels up (dashboard/ moved to the repo root, #1106);
    # inside the dashboard image the tests live at /app/tests and there is no repo root at all —
    # parents[3] itself raises there, so the lookup must fail soft for the skipif to see "absent".
    try:
        root = Path(__file__).parents[3]
    except IndexError:
        return None
    return (
        root
        / "docs"
        / "research"
        / "xvb-delivery-study"
        / "data"
        / "sources"
        / "xmrvsbeast-reward_estimate_pub.txt"
    )


_XVB_ARCHIVE = _xvb_archive()


def _summary_earnings(**over):
    """A minimal build_earnings-shaped dict — only the keys build_earnings_vs_actual reads."""
    e = {
        "coeff_day": 0.0,
        "confirmed": {"enabled": False},
        "tari_confirmed": {"enabled": False},
        "xvb_day": None,
    }
    e.update(over)
    return e


_WINS_TIERS = {"donor": 1_000.0, "donor_vip": 10_000.0, "donor_whale": 100_000.0}

_WINS_STATS = {
    "stats": {
        "types": {
            "donor": {"rounds": 7, "players_avg": 70.0},
            "donor_vip": {"rounds": 28, "players_avg": 28.0},
            "donor_whale": {"rounds": 56, "players_avg": 8.0},
        },
        "span_days": 7.0,
    },
    "last_update": None,  # set fresh per test
}


def _round_state(stale=False):
    ts = time.time() - (XVB_STATS_STALE_AFTER_S + 1 if stale else 0)
    return {**_WINS_STATS, "last_update": ts}


_REALIZATION_NOW = 1_760_000_000


__all__ = [name for name in globals() if not name.startswith("__")]
