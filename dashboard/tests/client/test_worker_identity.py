import json

import pytest

from mining_dashboard.client import xmrig_client as xc
from mining_dashboard.client.xmrig_client import (
    XMRigWorkerClient,
    _worker_override,
    parse_rigforge,
)

RIG_ID = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"
OTHER_ID = "f1e2d3c4b5a6978800112233aabbccdd"


class _Response:
    def __init__(self, status, payload):
        self.status = status
        self._raw = json.dumps(payload).encode()
        self._pos = 0
        self.content = self

    async def read(self, n=-1):
        end = len(self._raw) if n < 0 else min(len(self._raw), self._pos + n)
        chunk, self._pos = self._raw[self._pos : end], end
        return chunk


class _Get:
    def __init__(self, response):
        self._response = response

    async def __aenter__(self):
        return self._response

    async def __aexit__(self, *exc):
        return False


class _Session:
    def __init__(self, status=200, payload=None):
        self._response = _Response(status, {"ok": True} if payload is None else payload)
        self.calls = []

    def get(self, url, headers=None, timeout=None):
        self.calls.append((url, headers))
        return _Get(self._response)


async def _probe(monkeypatch, entries, payload, ip="10.0.0.1", name="rig1"):
    monkeypatch.setattr(xc, "WORKER_ENDPOINTS", entries)
    session = _Session(payload=payload)
    result = await XMRigWorkerClient(session).get_stats(ip, name)
    return result, session


def _rf(**fields):
    return {"ok": True, "rigforge": fields}


def test_feed_identity_fields_surface():
    rf = parse_rigforge(
        _rf(
            version="1.7.0",
            rig_id=RIG_ID,
            os_version="Debian GNU/Linux 13",
            identity={"mac": "aa:bb:cc", "board_uuid": "0123456789abc", "cpu_model": "EPYC"},
        )
    )
    assert rf["rig_id"] == RIG_ID
    assert rf["os_version"] == "Debian GNU/Linux 13"
    assert rf["identity"] == {"mac": "aa:bb:cc", "board_uuid": "0123456789abc", "cpu_model": "EPYC"}


def test_older_feed_without_the_new_fields_reads_unknown_not_error():
    rf = parse_rigforge({"ok": True, "rigforge": {"version": "1.7.0"}})
    assert rf is not None
    assert rf["rig_id"] is None
    assert rf["os_version"] is None
    assert rf["identity"] is None


def test_no_rigforge_block_at_all_still_parses_as_none():
    assert parse_rigforge({"ok": True}) is None


@pytest.mark.parametrize("claim", ["   ", "", None, 123, True])
def test_whitespace_and_null_shapes_of_rig_id_are_unknown(claim):
    assert parse_rigforge(_rf(rig_id=claim))["rig_id"] is None


@pytest.mark.parametrize("claim", ["   ", "", None, 123])
def test_whitespace_and_null_shapes_of_os_version_are_unknown(claim):
    assert parse_rigforge(_rf(os_version=claim))["os_version"] is None


def test_surrounding_whitespace_is_trimmed():
    rf = parse_rigforge(_rf(rig_id=f"  {RIG_ID} ", os_version="  Fedora  42  "))
    assert rf["rig_id"] == RIG_ID
    assert rf["os_version"] == "Fedora  42"


@pytest.mark.parametrize("identity", [None, "not-a-dict", 42, {}])
def test_identity_absent_or_garbage_is_none(identity):
    assert parse_rigforge(_rf(identity=identity))["identity"] is None


def test_identity_with_no_hint_found_is_none_not_an_empty_dict():
    block = {"mac": None, "board_uuid": None, "cpu_model": None}
    assert parse_rigforge(_rf(identity=block))["identity"] is None


def test_identity_keeps_found_hints_beside_the_ones_the_probe_missed():
    block = {"mac": None, "board_uuid": None, "cpu_model": " EPYC "}
    assert parse_rigforge(_rf(identity=block))["identity"] == {
        "mac": None,
        "board_uuid": None,
        "cpu_model": "EPYC",
    }


def _entries():
    return [
        {"name": "rig-a", "host": "10.0.0.1"},
        {"name": "rig-b", "host": "10.0.0.2", "rig_id": RIG_ID, "token": "t0k"},
    ]


def test_id_match_wins_over_a_name_match_when_both_sides_carry_ids(monkeypatch):
    monkeypatch.setattr(xc, "WORKER_ENDPOINTS", _entries())
    assert _worker_override("rig-a", "10.0.0.9", RIG_ID)["name"] == "rig-b"


def test_a_name_match_whose_ids_differ_never_silently_adopts(monkeypatch):
    monkeypatch.setattr(xc, "WORKER_ENDPOINTS", _entries())
    assert _worker_override("rig-b", "10.0.0.9", OTHER_ID) is None


def test_a_host_match_whose_ids_differ_is_skipped_too(monkeypatch):
    monkeypatch.setattr(xc, "WORKER_ENDPOINTS", _entries())
    assert _worker_override("other-name", "10.0.0.2", OTHER_ID) is None


def test_a_renamed_rig_keeping_its_id_still_finds_its_entry(monkeypatch):
    monkeypatch.setattr(xc, "WORKER_ENDPOINTS", _entries())
    assert _worker_override("brand-new-name", "10.9.9.9", RIG_ID)["name"] == "rig-b"


def test_an_unknown_id_answers_exactly_like_no_id_for_a_record_without_one(monkeypatch):
    monkeypatch.setattr(xc, "WORKER_ENDPOINTS", [{"name": "rig-a", "host": "10.0.0.1"}])
    assert _worker_override("rig-a", None, OTHER_ID)["name"] == "rig-a"
    assert _worker_override("rig-a", None) is not None


def test_without_a_claimed_id_matching_is_name_then_host_as_before(monkeypatch):
    monkeypatch.setattr(xc, "WORKER_ENDPOINTS", _entries())
    assert _worker_override("rig-b", "10.0.0.1")["name"] == "rig-b"
    assert _worker_override("whatever", "10.0.0.1")["name"] == "rig-a"


async def test_a_successful_feed_claiming_the_recorded_id_is_business_as_usual(monkeypatch):
    entries = [
        {
            "name": "rig1",
            "host": "10.0.0.1",
            "token": {"__secret__": True},
            "read_token": "readonly",
            "rig_id": RIG_ID,
        }
    ]
    result, _ = await _probe(monkeypatch, entries, _rf(rig_id=RIG_ID))
    assert result["api_ok"] is True
    assert result["adopted"] is True
    assert result["identity_change"] is False


async def test_a_same_name_feed_with_a_different_id_surfaces_an_identity_change(monkeypatch):
    entries = [
        {
            "name": "rig1",
            "host": "10.0.0.1",
            "token": {"__secret__": True},
            "read_token": "readonly",
            "rig_id": RIG_ID,
        }
    ]
    result, _ = await _probe(monkeypatch, entries, _rf(rig_id=OTHER_ID))
    assert result["api_ok"] is True
    assert result["adopted"] is False
    assert result["identity_change"] is True
    assert result["rigforge"]["rig_id"] == OTHER_ID
    assert entries[0]["rig_id"] == RIG_ID
    assert "adopted" not in entries[0]


async def test_a_claimed_id_that_matches_another_recorded_rig_follows_the_id(monkeypatch):
    entries = [
        {"name": "rig1", "host": "10.0.0.1", "rig_id": RIG_ID},
        {"name": "rig2", "host": "10.0.0.2", "token": "t0k", "rig_id": OTHER_ID},
    ]
    result, _ = await _probe(monkeypatch, entries, _rf(rig_id=OTHER_ID), name="rig1")
    assert result["api_ok"] is True
    assert result["adopted"] is True
    assert result["identity_change"] is False


async def test_an_unknown_claim_on_a_record_without_an_id_changes_nothing(monkeypatch):
    entries = [
        {
            "name": "rig1",
            "host": "10.0.0.1",
            "token": {"__secret__": True},
            "read_token": "readonly",
        }
    ]
    result, _ = await _probe(monkeypatch, entries, _rf(rig_id=OTHER_ID))
    assert result["api_ok"] is True
    assert result["adopted"] is True
    assert result["identity_change"] is False


async def test_an_unknown_id_answers_exactly_like_a_feed_that_carries_none(monkeypatch):
    entries = [
        {
            "name": "rig1",
            "host": "10.0.0.1",
            "token": {"__secret__": True},
            "read_token": "readonly",
        }
    ]
    silent, _ = await _probe(monkeypatch, entries, {"ok": True})
    claimed, _ = await _probe(monkeypatch, entries, _rf(rig_id=OTHER_ID))
    assert {k: v for k, v in claimed.items() if k != "rigforge"} == silent


@pytest.mark.parametrize("claim", [None, "   ", ""])
async def test_a_whitespace_or_absent_claim_never_flags_anything(monkeypatch, claim):
    entries = [{"name": "rig1", "host": "10.0.0.1", "rig_id": RIG_ID}]
    result, _ = await _probe(monkeypatch, entries, _rf(rig_id=claim))
    assert result["api_ok"] is True
    assert result["identity_change"] is False


async def test_a_feed_id_never_becomes_a_credential(monkeypatch):
    entries = [{"name": "rig1", "host": "10.0.0.1", "read_token": "readonly", "rig_id": RIG_ID}]
    result, session = await _probe(monkeypatch, entries, _rf(rig_id=OTHER_ID))
    assert session.calls[0][1]["Authorization"] == "Bearer readonly"
    assert OTHER_ID not in json.dumps(session.calls)


async def test_a_failing_probe_never_flags_an_identity_change(monkeypatch):
    entries = [
        {
            "name": "rig1",
            "host": "10.0.0.1",
            "token": {"__secret__": True},
            "read_token": "readonly",
            "rig_id": RIG_ID,
        }
    ]
    monkeypatch.setattr(xc, "WORKER_ENDPOINTS", entries)
    result = await XMRigWorkerClient(_Session(status=401)).get_stats("10.0.0.1", "rig1")
    assert result == {"api_ok": False, "adopted": True}


async def test_a_renamed_moved_rig_found_only_by_its_id_keeps_its_record(monkeypatch):
    entries = [{"name": "old-name", "host": "10.0.0.1", "token": "t0k", "rig_id": RIG_ID}]
    result, session = await _probe(
        monkeypatch, entries, _rf(rig_id=RIG_ID), ip="10.9.9.9", name="new-name"
    )
    assert result["api_ok"] is True
    assert result["adopted"] is True
    assert result["identity_change"] is False
    assert session.calls[0][0] == "http://10.9.9.9:8080/1/summary"
    assert "Authorization" not in session.calls[0][1]


async def test_a_renamed_rig_claiming_an_unknown_id_stays_unadopted(monkeypatch):
    entries = [{"name": "old-name", "host": "10.0.0.1", "token": "t0k", "rig_id": RIG_ID}]
    result, _ = await _probe(
        monkeypatch, entries, _rf(rig_id=OTHER_ID), ip="10.9.9.9", name="new-name"
    )
    assert result["api_ok"] is True
    assert result["adopted"] is False
    assert result["identity_change"] is False


async def test_a_feed_forging_the_identity_change_flag_is_overruled(monkeypatch):
    entries = [{"name": "rig1", "host": "10.0.0.1", "rig_id": RIG_ID}]
    payload = _rf(rig_id=RIG_ID)
    payload["identity_change"] = True
    result, _ = await _probe(monkeypatch, entries, payload)
    assert result["api_ok"] is True
    assert result["identity_change"] is False
