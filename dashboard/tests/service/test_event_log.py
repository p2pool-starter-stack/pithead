import time as _time_module
from unittest.mock import patch

import pytest

from mining_dashboard.service.storage_service import StateManager


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


def _sm(clock=None):
    sm = StateManager(db_path=":memory:")
    return sm


def _patch_time(clock):
    patcher = patch("mining_dashboard.service.event_log_store.time", _FakeTime(clock))
    patcher.start()
    return patcher


class _FakeTime:
    def __init__(self, clock):
        self._clock = clock

    def time(self):
        return self._clock()


def test_error_opens_episode():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("connect", "pool", "Connect to pool", "error",
                        "connection refused", {})
        episodes = sm.get_open_episodes()
        assert len(episodes) == 1
        assert episodes[0]["kind"] == "connect"
        assert episodes[0]["subject"] == "pool"
        assert episodes[0]["count"] == 1
        assert episodes[0]["end_ts"] is None
    finally:
        p.stop()
    sm.close()


def test_normal_event_does_not_open_episode():
    sm = StateManager(db_path=":memory:")
    sm.record_event("connect", "pool", "Connect to pool", "normal",
                    "connected", {})
    assert len(sm.get_open_episodes()) == 0
    sm.close()


def test_repeat_increments_count_and_updates_ts():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("connect", "pool", "Connect to pool", "error",
                        "connection refused", {})
        clock.advance(60)
        sm.record_event("connect", "pool", "Connect to pool", "error",
                        "connection refused", {})
        episodes = sm.get_open_episodes()
        assert len(episodes) == 1
        assert episodes[0]["count"] == 2
    finally:
        p.stop()
    sm.close()


def test_repeat_bypasses_per_minute_rate_limit():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("connect", "pool", "Connect to pool", "error",
                        "connection refused", {})
        clock.advance(5)
        sm.record_event("connect", "pool", "Connect to pool", "error",
                        "connection refused", {})
        episodes = sm.get_open_episodes()
        assert len(episodes) == 1
        assert episodes[0]["count"] == 2
    finally:
        p.stop()
    sm.close()


def test_close_by_success():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("connect", "pool", "Connect to pool", "error",
                        "connection refused", {})
        clock.advance(30)
        sm.record_event("connect", "pool", "Connect to pool", "normal",
                        "connected", {})
        episodes = sm.get_open_episodes()
        assert len(episodes) == 0
    finally:
        p.stop()
    sm.close()


def test_close_by_success_different_kind_does_not_close():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("connect", "pool", "Connect to pool", "error",
                        "connection refused", {})
        clock.advance(30)
        sm.record_event("sync", "chain", "Sync chain", "normal",
                        "synced", {})
        episodes = sm.get_open_episodes()
        assert len(episodes) == 1
        assert episodes[0]["kind"] == "connect"
    finally:
        p.stop()
    sm.close()


def test_close_by_timeout():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("connect", "pool", "Connect to pool", "error",
                        "connection refused", {})
        clock.advance(30 * 60 + 1)
        episodes = sm.get_open_episodes()
        assert len(episodes) == 1
    finally:
        p.stop()
    sm.close()


def test_reopen_after_close_by_success():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("connect", "pool", "Connect to pool", "error",
                        "connection refused", {})
        clock.advance(30)
        sm.record_event("connect", "pool", "Connect to pool", "normal",
                        "connected", {})
        clock.advance(10)
        sm.record_event("connect", "pool", "Connect to pool", "error",
                        "reconnection failed", {})
        episodes = sm.get_open_episodes()
        assert len(episodes) == 1
        assert episodes[0]["count"] == 1
    finally:
        p.stop()
    sm.close()


def test_get_open_episodes_returns_open_only():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("a", "x", "Err", "error", "err", {})
        sm.record_event("b", "y", "Err", "error", "err", {})
        clock.advance(30)
        sm.record_event("a", "x", "OK", "normal", "ok", {})
        episodes = sm.get_open_episodes()
        assert len(episodes) == 1
        assert episodes[0]["kind"] == "b"
    finally:
        p.stop()
    sm.close()


def test_episode_state_survives_restart(tmp_path):
    db = str(tmp_path / "restart.db")
    clock = Clock()
    p = _patch_time(clock)
    try:
        sm = StateManager(db_path=db)
        sm.record_event("connect", "pool", "Connect", "error",
                        "refused", {})
        sm.close()

        sm2 = StateManager(db_path=db)
        episodes = sm2.get_open_episodes()
        assert len(episodes) == 1
        assert episodes[0]["kind"] == "connect"
        assert episodes[0]["subject"] == "pool"
        sm2.close()
    finally:
        p.stop()