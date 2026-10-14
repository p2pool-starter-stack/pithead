"""The lone-surrogate bind on `add_worker_history` (#1806), second site of the #1696 class.

`add_worker_history` binds the rig-chosen worker NAME into its `executemany` INSERT — the enriched
feed's name for every `online` worker, batched once per poll under `asyncio.to_thread` — and used
to catch `sqlite3.Error` alone. `UnicodeEncodeError` is a `ValueError`, so a lone surrogate
(U+D800) in a rig's chosen name escaped that handler exactly as it did at the three
`worker_config_store` binds #1696 fixed, aborting the batch and losing every OTHER online rig's
sample for that tick too.

This is a batch write, so the fix is per row rather than per call (per the issue's own suggested
shape): a row whose `name` sqlite cannot bind is dropped, the rest of the batch still lands. Uses
the same `_bindable` predicate `worker_config_store` binds its own rig-chosen strings through,
rather than a second copy of the encode check.

Paired with a positive control for the same reason `test_worker_config_surrogates.py` has one:
"did not raise" is the weakest assertion there is.
"""

import time

import pytest

SURROGATE = "\ud800"


class TestTheSurrogateIsGenuinelyHostile:
    def test_a_bare_bind_of_it_still_raises(self, state_manager):
        with state_manager._db_lock, pytest.raises(UnicodeEncodeError):
            state_manager._conn.execute("SELECT ?", (SURROGATE,))


class TestAddWorkerHistorySurrogateName:
    def test_a_surrogate_name_does_not_abort_the_batch(self, state_manager):
        # RED without the fix: this call raised UnicodeEncodeError and the batch, including
        # rig1's clean sample below, was lost.
        t0 = time.time()
        state_manager.add_worker_history(
            [
                {"ts": t0, "name": SURROGATE, "h15": 1.0, "accepted": 1, "rejected": 0},
                {"ts": t0, "name": "rig1", "h15": 2.0, "accepted": 2, "rejected": 0},
            ]
        )
        rows = state_manager.get_worker_history()
        assert {r["name"] for r in rows} == {"rig1"}

    def test_a_batch_of_only_hostile_names_is_a_clean_no_op(self, state_manager):
        state_manager.add_worker_history(
            [{"ts": time.time(), "name": SURROGATE, "h15": 1.0, "accepted": 0, "rejected": 0}]
        )
        assert state_manager.get_worker_history() == []

    def test_a_clean_batch_is_unaffected(self, state_manager):
        # CONTROL: the fix must not touch an all-clean batch.
        t0 = time.time()
        state_manager.add_worker_history(
            [
                {"ts": t0, "name": "rig1", "h15": 1.0, "accepted": 1, "rejected": 0},
                {"ts": t0, "name": "rig2", "h15": 2.0, "accepted": 2, "rejected": 0},
            ]
        )
        rows = state_manager.get_worker_history()
        assert {r["name"] for r in rows} == {"rig1", "rig2"}
