"""OwedStart (#2464): a start owed to a container this dashboard stopped, across its restarts."""

import asyncio
import json
import os
import time
from unittest.mock import AsyncMock

from mining_dashboard.service.health.owed_start import OwedStart


def age_record(path, seconds):
    """Move a record's stop time ``seconds`` into the past, as if that much time had passed."""
    record = json.loads(path.read_text())
    record["stopped_at"] -= seconds
    path.write_text(json.dumps(record))


def _stopped(started_at):
    async def inspect(name):
        return False, started_at

    return inspect


def test_an_unreadable_record_owes_one_start_from_the_file_age(tmp_path):
    rec = OwedStart(str(tmp_path), "tari", 5, _stopped(time.time() - 3600))
    (tmp_path / "tari-start-owed").write_text("{not json")
    docker = AsyncMock()
    docker.start.return_value = False
    assert asyncio.run(rec.retry(docker)) == "start_gave_up"
    assert json.loads((tmp_path / "tari-start-owed").read_text())["retries"] == 0
    assert asyncio.run(rec.retry(docker)) == "start_gave_up" and docker.start.await_count == 1


def test_a_record_settled_meanwhile_owes_nothing(tmp_path):
    rec = OwedStart(str(tmp_path), "tari", 5, _stopped(0))
    assert asyncio.run(rec.retry(AsyncMock())) == "start_settled"
    rec.settle()  # already gone: no error


def test_an_unwritable_state_dir_is_logged_not_raised(tmp_path, caplog):
    rec = OwedStart(str(tmp_path / "missing"), "p2pool")
    rec.owe()
    assert not rec.pending() and "Could not record the start owed to p2pool" in caplog.text


def test_a_record_that_cannot_be_removed_is_logged(tmp_path, caplog):
    rec = OwedStart(str(tmp_path), "p2pool")
    os.mkdir(tmp_path / "p2pool-start-owed")  # a directory: os.remove refuses it
    rec.settle()
    assert "Could not remove" in caplog.text


def test_a_running_container_within_the_stop_grace_stays_owed(tmp_path):
    """A stop reported failed may still be landing: running, within the grace, is not proof."""

    async def running(name):
        return True, time.time() - 3600

    rec = OwedStart(str(tmp_path), "p2pool", inspect=running, grace=60)
    rec.owe()
    assert rec.stopping() and asyncio.run(rec.retry(AsyncMock())) == "start_pending"
    age_record(tmp_path / "p2pool-start-owed", 61)
    assert not rec.stopping() and asyncio.run(rec.retry(AsyncMock())) == "stop_missed"
    assert not rec.pending() and not rec.stopping()
