import asyncio
import json
from unittest.mock import MagicMock

import pytest

from mining_dashboard.client import xmrig_client
from mining_dashboard.service import control_service
from mining_dashboard.service.data_service import DataService
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.service.workers import worker_identity, worker_identity_poll
from mining_dashboard.service.workers.worker_identity import (
    IDENTITY_WINDOW_S,
    RigIdentityTracker,
)

RIG = "a" * 32
HINTS_A = {"mac": "aa:aa", "board_uuid": None, "cpu_model": "A72"}
HINTS_B = {"mac": "bb:bb", "board_uuid": None, "cpu_model": "A72"}


def _row(ip, name="rig1"):
    return {"name": name, "ip": ip, "status": "online"}


def _reply(hints=None, rig_id=RIG):
    return {
        "api_ok": True,
        "rigforge": {"rig_id": rig_id, "identity": hints, "version": "v1.19.0"},
    }


@pytest.fixture
def svc(monkeypatch):
    sm = StateManager(db_path=":memory:")
    monkeypatch.setattr(xmrig_client, "WORKER_ENDPOINTS", [])
    monkeypatch.setattr(worker_identity, "_faulted_names", frozenset())
    yield DataService(sm, MagicMock(), MagicMock())
    sm.close()


def _poll(svc, rows, replies, now):
    asyncio.run(worker_identity_poll.observe_poll(svc, rows, replies, now=now))
    marked = [dict(r, rigforge=r.get("rigforge") or {"rig_id": RIG}) for r in rows]
    return worker_identity.mark_duplicates(svc, marked, now=now)


class TestTracker:
    def test_two_sources_within_the_window_raise_the_fault(self):
        t = RigIdentityTracker()
        t.observe(RIG, "10.0.0.1", None, None, 100)
        assert not t.faulted(RIG, 100)
        t.observe(RIG, "10.0.0.2", None, None, 101)
        assert t.faulted(RIG, 101)

    def test_fault_decays_when_one_source_goes_quiet(self):
        t = RigIdentityTracker()
        t.observe(RIG, "10.0.0.1", None, None, 100)
        t.observe(RIG, "10.0.0.2", None, None, 100)
        later = 100 + IDENTITY_WINDOW_S + 1
        t.observe(RIG, "10.0.0.1", None, None, later)
        assert not t.faulted(RIG, later)

    def test_a_credential_change_clears_the_fault(self):
        t = RigIdentityTracker()
        t.observe(RIG, "10.0.0.1", None, "old", 100)
        t.observe(RIG, "10.0.0.2", None, "old", 100)
        assert t.faulted(RIG, 100)
        t.observe(RIG, "10.0.0.1", None, "new", 101)
        assert not t.faulted(RIG, 101)

    def test_one_source_with_changing_hints_is_moved_not_a_fault(self):
        t = RigIdentityTracker()
        assert t.observe(RIG, "10.0.0.1", (("mac", "aa"),), None, 100) is False
        assert t.observe(RIG, "10.0.0.1", (("mac", "bb"),), None, 101) is True
        assert not t.faulted(RIG, 101)


class TestPoll:
    def test_two_simulated_sources_raise_and_decay(self, svc):
        rows = [_row("10.0.0.1"), _row("10.0.0.2")]
        replies = [_reply(), _reply()]
        marked = _poll(svc, rows, replies, 1000)
        assert all(w["duplicate_identity"] for w in marked)
        assert worker_identity._faulted_names == {"rig1"}
        quiet = 1000 + IDENTITY_WINDOW_S + 1
        marked = _poll(svc, rows[:1], replies[:1], quiet)
        assert not marked[0]["duplicate_identity"]
        assert worker_identity._faulted_names == frozenset()

    def test_an_offline_or_unanswered_row_is_not_a_source(self, svc):
        rows = [_row("10.0.0.1"), dict(_row("10.0.0.2"), status="offline")]
        marked = _poll(svc, rows, [_reply(), _reply()], 1000)
        assert not any(w["duplicate_identity"] for w in marked)
        marked = _poll(svc, [_row("10.0.0.3")], [{"api_ok": False}], 1001)
        assert not marked[0]["duplicate_identity"]

    def test_rekeying_one_copy_clears_the_fault(self, svc, monkeypatch):
        rows = [_row("10.0.0.1"), _row("10.0.0.2")]
        replies = [_reply(), _reply()]
        monkeypatch.setattr(
            xmrig_client, "WORKER_ENDPOINTS", [{"name": "rig1", "rig_id": RIG, "read_token": "t1"}]
        )
        assert _poll(svc, rows, replies, 1000)[0]["duplicate_identity"]
        monkeypatch.setattr(
            xmrig_client, "WORKER_ENDPOINTS", [{"name": "rig1", "rig_id": RIG, "read_token": "t2"}]
        )
        marked = _poll(svc, rows[:1], replies[:1], 1001)
        assert not marked[0]["duplicate_identity"]

    def test_same_id_different_hints_from_one_source_is_an_info_event(self, svc):
        _poll(svc, [_row("10.0.0.1")], [_reply(HINTS_A)], 1000)
        marked = _poll(svc, [_row("10.0.0.1")], [_reply(HINTS_B)], 1001)
        assert not marked[0]["duplicate_identity"]
        events = svc.state_manager.get_audit_events()
        assert [(e["source"], e["action"], e["status"]) for e in events] == [
            ("rig-identity", "moved-hardware", "info")
        ]
        _poll(svc, [_row("10.0.0.1")], [_reply(HINTS_B)], 1002)
        assert len(svc.state_manager.get_audit_events()) == 1


class TestControlStamp:
    @pytest.fixture
    def spool(self, tmp_path, monkeypatch):
        (tmp_path / "requests").mkdir()
        (tmp_path / "results").mkdir()
        monkeypatch.setattr(
            control_service.config, "CONTROL_REQUESTS_DIR", str(tmp_path / "requests")
        )
        monkeypatch.setattr(
            control_service.config, "CONTROL_RESULTS_DIR", str(tmp_path / "results")
        )
        return tmp_path / "requests"

    def _spooled(self, spool, rid):
        return json.loads((spool / f"{rid}.json").read_text())

    def test_verbs_carry_the_fault_only_while_it_is_set(self, spool, monkeypatch):
        monkeypatch.setattr(worker_identity, "_faulted_names", frozenset({"rig1"}))
        for submit in (
            lambda w: control_service.submit_worker_apply(w, {"DONATION": 1}, "admin"),
            lambda w: control_service.submit_worker_upgrade(w, "v1.11.2", "admin"),
        ):
            assert self._spooled(spool, submit("rig1"))["duplicate_identity"] is True
            assert "duplicate_identity" not in self._spooled(spool, submit("rig2"))
        monkeypatch.setattr(worker_identity, "_faulted_names", frozenset())
        rid = control_service.submit_worker_apply("rig1", {"DONATION": 1}, "admin")
        assert "duplicate_identity" not in self._spooled(spool, rid)
