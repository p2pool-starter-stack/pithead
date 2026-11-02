import asyncio
import threading
from types import SimpleNamespace

import pytest

from mining_dashboard import go_wizard_terminal

# ruff: noqa: S101


@pytest.mark.parametrize("cancel_first", [False, True])
@pytest.mark.asyncio
async def test_retry_serializes_stage_and_cleanup_after_handler_cancellation(
    tmp_path, monkeypatch, cancel_first
):
    failure = tmp_path / "setup-failed"
    failure.write_text("1")
    monkeypatch.setenv("WIZARD_SPOOL", str(tmp_path))
    first_entered = threading.Event()
    release_first = threading.Event()
    second_stage_entered = threading.Event()
    second_authenticated = asyncio.Event()
    auth_calls = []
    stage_calls = []
    first = None
    second = None

    def authed(request):
        auth_calls.append(request)
        if len(auth_calls) == 2:
            second_authenticated.set()
        return True

    def stage():
        stage_calls.append(failure.exists())
        if len(stage_calls) == 1:
            first_entered.set()
            if not release_first.wait(5):
                raise TimeoutError("first retry stage was not released")
        else:
            second_stage_entered.set()
        return "failed" if failure.exists() else "setup"

    handler = go_wizard_terminal.retry_handler(authed, stage, lambda: tmp_path)
    try:
        first = asyncio.create_task(handler(SimpleNamespace()))
        assert await asyncio.wait_for(asyncio.to_thread(first_entered.wait, 5), 6)
        if cancel_first:
            first.cancel()
            with pytest.raises(asyncio.CancelledError):
                await asyncio.wait_for(first, 2)
        second = asyncio.create_task(handler(SimpleNamespace()))
        await asyncio.wait_for(second_authenticated.wait(), 2)
        assert not await asyncio.wait_for(asyncio.to_thread(second_stage_entered.wait, 0.1), 1)
        assert len(stage_calls) == 1
        release_first.set()
        if not cancel_first:
            first_response = await asyncio.wait_for(first, 5)
            assert first_response.status == 200
        second_response = await asyncio.wait_for(second, 5)
        assert second_response.status == 409
        assert stage_calls == [True, False]
        assert not failure.exists()
    finally:
        release_first.set()
        pending = [task for task in (first, second) if task is not None and not task.done()]
        if pending:
            await asyncio.wait_for(asyncio.gather(*pending, return_exceptions=True), 6)
