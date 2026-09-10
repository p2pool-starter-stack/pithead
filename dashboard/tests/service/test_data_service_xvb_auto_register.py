# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestXvbAutoRegister:
    """XvB raffle auto-registration gating (#263)."""

    def _svc(self, submit_url="https://xvb.example/submit"):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        xvb = MagicMock()
        xvb.submit_url = submit_url  # configured by default; pass "" for the unconfigured case
        svc = DataService(sm, MagicMock(), xvb)
        return svc, sm, xvb

    def _stats(self, pplns_window=2160, pool_type="Main"):
        return {"p2p": {"type": pool_type}, "pool": {"pplns_window": pplns_window}}

    def _fresh_share(self):
        return [{"ts": time.time()}]

    def _state_writes(self, sm):
        """Merged kwargs across all update_xvb_stats calls (the persisted XvB-state writes)."""
        merged = {}
        for call in sm.update_xvb_stats.call_args_list:
            merged.update(call.kwargs)
        return merged

    async def test_no_share_does_not_register(self):
        # Endpoint only takes effect with a PPLNS share, so we don't even call it before then.
        svc, _sm, xvb = self._svc()
        await svc._maybe_register_xvb(shares=[], p2pool_stats=self._stats())
        xvb.register.assert_not_called()
        assert svc._xvb_last_registered is None

    async def test_stale_share_outside_window_does_not_register(self):
        svc, _sm, xvb = self._svc()
        # 2160 blocks * 10s = 6h window; a share 7h old is outside it.
        stale = [{"ts": time.time() - 7 * 3600}]
        await svc._maybe_register_xvb(shares=stale, p2pool_stats=self._stats())
        xvb.register.assert_not_called()

    async def test_registers_once_eligible(self):
        # REG_OK covers both a fresh 2xx and the idempotent "already registered" steady state.
        svc, sm, xvb = self._svc()
        xvb.register.return_value = REG_OK
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        xvb.register.assert_called_once()
        assert svc._xvb_last_registered is not None
        writes = self._state_writes(sm)
        assert "registered_at" in writes
        assert writes["registration_state"] == "registered"

    async def test_transient_error_retries_next_poll(self):
        # A transient error must NOT latch the timestamp, so the next eligible poll retries; and one
        # blip stays below the failing threshold (no dashboard warning yet).
        svc, sm, xvb = self._svc()
        xvb.register.return_value = REG_ERROR
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        assert svc._xvb_last_registered is None
        assert svc._xvb_register_failures == 1
        assert "registration_state" not in self._state_writes(sm)

    async def test_not_eligible_is_quiet_retry(self):
        # Local share hasn't propagated to XvB yet => retry quietly, NOT counted as a failure.
        svc, sm, xvb = self._svc()
        xvb.register.return_value = REG_NOT_ELIGIBLE
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        assert svc._xvb_register_failures == 0
        sm.update_xvb_stats.assert_not_called()
        assert svc._xvb_last_registered is None  # not registered, will retry

    async def test_invalid_wallet_latches_and_warns(self, caplog):
        # Permanent rejection: surface "invalid", warn once, and stop calling the endpoint.
        svc, sm, xvb = self._svc()
        xvb.register.return_value = REG_INVALID
        with caplog.at_level("WARNING"):
            await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
            await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        xvb.register.assert_called_once()  # latched after the first rejection — no re-hammering
        assert self._state_writes(sm)["registration_state"] == "invalid"
        assert sum("rejected MONERO_WALLET_ADDRESS" in r.message for r in caplog.records) == 1

    async def test_skips_when_recently_registered(self):
        svc, _sm, xvb = self._svc()
        svc._xvb_last_registered = time.time()  # just registered
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        xvb.register.assert_not_called()

    async def test_reregisters_after_interval(self):
        # Idempotent daily re-register once the cadence elapses.
        svc, _sm, xvb = self._svc()
        xvb.register.return_value = REG_OK
        svc._xvb_last_registered = time.time() - XVB_REGISTER_INTERVAL_S - 1
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        xvb.register.assert_called_once()

    async def test_disabled_endpoint_skips_silently(self):
        # XVB_SUBMIT_URL disabled => empty submit_url => no call, no warning, no status write.
        svc, sm, xvb = self._svc(submit_url="")
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        xvb.register.assert_not_called()
        sm.update_xvb_stats.assert_not_called()

    async def test_persistent_failure_flags_failing_after_threshold(self):
        # A configured-but-erroring endpoint surfaces a "failing" badge only after a few attempts.
        svc, sm, xvb = self._svc()
        xvb.register.return_value = REG_ERROR
        for _ in range(_XVB_REGISTER_FAIL_ALERT - 1):
            await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        # Below the threshold: no dashboard warning yet.
        assert "registration_state" not in self._state_writes(sm)
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        assert self._state_writes(sm)["registration_state"] == "failing"
        assert svc._xvb_last_registered is None  # still never succeeded

    async def test_success_after_failures_resets_counter(self):
        svc, sm, xvb = self._svc()
        xvb.register.return_value = REG_ERROR
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        assert svc._xvb_register_failures == 1
        xvb.register.return_value = REG_OK
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        assert svc._xvb_register_failures == 0
        assert self._state_writes(sm)["registration_state"] == "registered"
