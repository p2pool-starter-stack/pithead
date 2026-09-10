import logging

logger = logging.getLogger("DataService")


def _runtime():
    from mining_dashboard.service import data_service

    return data_service


class DataGateMixin:
    async def _apply_worker_rejection(self, monero_down):
        """
        Reject workers (stop the proxy) when monerod is DOWN so miners fail over to their
        backup pools; readmit them (start the proxy) once monerod is confirmed healthy again.

        monerod is required to mine, so a monerod outage always rejects. Tari never rejects
        workers (Issue #897): it's merge-mining gravy, and p2pool keeps mining Monero through
        a Tari-only outage, so stopping the proxy over Tari alone traded partial revenue for
        none. `TARI_REQUIRED` (dashboard.tari_required) still gates the initial-sync hold and
        the full-screen sync view (see `_apply_sync_gate`); a Tari outage still surfaces
        through the Tari panel and alerts. Only acts on transitions (tracked by
        `workers_rejected`), and Docker treats a repeat stop/start as already-done (HTTP 304),
        so it's safe every cycle.
        """
        if monero_down and not self.workers_rejected:
            logger.warning(
                f"Required node unreachable — stopping {_runtime().REJECT_WORKERS_CONTAINER} so workers "
                f"fail over to their backup pools."
            )
            if await self.docker_control.stop(_runtime().REJECT_WORKERS_CONTAINER):
                self.workers_rejected = True
            return

        # Readmit once monerod is confirmed healthy (not merely 'not down'), so a dashboard
        # restart mid-outage doesn't bring workers back to a stack that can't mine. Tari can no
        # longer be the reason workers were rejected, so its health plays no part in readmission.
        recovered = self.monero_health.healthy
        if self.workers_rejected and recovered:
            logger.info(
                f"Required nodes recovered — starting {_runtime().REJECT_WORKERS_CONTAINER} to readmit workers."
            )
            if await self.docker_control.start(_runtime().REJECT_WORKERS_CONTAINER):
                self.workers_rejected = False

    async def _stop_gate_containers(self, quiet):
        """Stop every ``SYNC_GATE_CONTAINERS`` container; shared by the #35 sync gate and the
        #490 fail-closed gate, the two holds that stop the same container set."""
        for container in _runtime().SYNC_GATE_CONTAINERS:
            await self.docker_control.stop(container, quiet=quiet)

    async def _start_gate_containers(self):
        """Start every ``SYNC_GATE_CONTAINERS`` container; True only if every start succeeded."""
        ok = True
        for container in _runtime().SYNC_GATE_CONTAINERS:
            ok = (await self.docker_control.start(container)) and ok
        return ok

    async def _apply_sync_gate(self, gate_satisfied):
        """
        Hold p2pool + xmrig-proxy stopped until the required chain(s) have fully synced once,
        then start them (Issue #35). Keeps p2pool from flooding Tari's logs with merge-mining
        junk during the long initial sync, when it can't usefully mine anyway.

        `gate_satisfied` is True once monerod is synced AND Tari is synced-or-non-blocking — so
        a non-blocking Tari (dashboard.tari_required:false) releases the miner as soon as
        monerod is ready and lets Tari finish in the background.

        One-way latch: once released we never re-hold, so this can't fight #31 (a transient
        node-down later stops only xmrig-proxy and keeps p2pool on the sidechain — that's #31's
        job, gated behind `miner_released` by the caller). While holding we re-assert the stop
        every cycle (quietly), so a `docker compose up` mid-sync — which would restart the held
        containers — is undone within a cycle.

        `gate_satisfied` must be derived from the *raw* per-node sync signals (RPC/gRPC), not
        the network-height UI override: that override is fed by p2pool's own stats file, so
        while p2pool is held it would read 0 and falsely report Monero as syncing forever.
        """
        if self.miner_released:
            return

        if gate_satisfied:
            if await self._start_gate_containers():
                self.miner_released = True
                self.miner_held = False
                logger.info(
                    f"Required chain(s) synced — starting {', '.join(_runtime().SYNC_GATE_CONTAINERS)}; mining can begin."
                )
            # On a partial-start failure leave the latch closed so the next cycle retries.
            return

        # Still syncing: keep the miner held. Log the human-facing notice only on the first
        # cycle of a hold; the per-cycle re-assert stops are quiet to avoid flooding the log.
        await self._stop_gate_containers(quiet=self.miner_held)
        if not self.miner_held:
            self.miner_held = True
            logger.info(
                f"Required chain(s) still syncing — holding {', '.join(_runtime().SYNC_GATE_CONTAINERS)} "
                f"until synced."
            )

    async def _apply_fail_closed_gate(self, unrecoverable):
        """
        Opt-in (`dashboard.fail_closed`, default False) miner hold on an UNRECOVERABLE health
        failure (#490) — reuses the #35 sync gate's own mechanism (stop/start
        ``SYNC_GATE_CONTAINERS`` through ``docker_control``) rather than a new hold path.

        "Unrecoverable" is scoped narrowly by the caller to genuine, non-transient failures: a DB
        whose auto-heal rebuild itself failed (``StateManager.is_db_unrecoverable``), or the
        dashboard container itself crash-looping / stuck unhealthy past the #337 debounce
        (``AlertService.containers.is_confirmed_bad("dashboard")`` — a debounce-CONFIRMED verdict,
        never a first-sighting seed). A transient write blip, a slow query, a single failed
        external fetch, or a container merely reported unhealthy on one poll is never
        "unrecoverable" — those already alert (#131/#337) and must never gate; a false positive
        here idles the fleet and costs revenue.

        Unlike the sync gate's one-way latch, this re-checks every cycle and releases once
        ``unrecoverable`` clears — the failures it watches (disk full, a crash-looping container)
        are the kind an operator fixes without a full stack restart, and the miner should resume
        on its own once they do. Only engages once the sync gate has actually released the miner;
        holding before that is already #35's job.

        Default False is alert-only: `dashboard.fail_closed` off means these same signals keep
        alerting (unchanged) but this method is a no-op, so a cosmetic dashboard fault never idles
        the fleet — the mining datapath (xmrig-proxy -> p2pool -> monerod) is independent of the
        dashboard by design.
        """
        if not _runtime().DASHBOARD_FAIL_CLOSED or not self.miner_released:
            return

        if unrecoverable:
            await self._stop_gate_containers(quiet=self.fail_closed_held)
            if not self.fail_closed_held:
                self.fail_closed_held = True
                logger.error(
                    f"Unrecoverable health failure with dashboard.fail_closed enabled — holding "
                    f"{', '.join(_runtime().SYNC_GATE_CONTAINERS)} until it clears."
                )
            return

        if self.fail_closed_held and await self._start_gate_containers():
            self.fail_closed_held = False
            logger.info(
                f"Unrecoverable health failure cleared — starting "
                f"{', '.join(_runtime().SYNC_GATE_CONTAINERS)}; mining can resume."
            )
