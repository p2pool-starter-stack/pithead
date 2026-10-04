import logging
import os

from mining_dashboard.config.config import DISK_PATH

logger = logging.getLogger("DataService")

# Written by the cross-hardware restore doors — the wizard and carried restores through
# restore_apply(), never `./pithead restore`'s same-box recovery (#2626 operator ruling: that
# door's chains never desynced, so it keeps whatever gate state the backup carried) — and by
# `apply` when a required chain moves to another node (#2763). Either way the snapshot's #35
# sync-gate latch was earned on other chains, so while this file exists the dashboard ignores
# the persisted release and re-derives it from the chains it now dials. Removed once the gate
# releases here.
SYNC_GATE_RESET_PATH = os.path.join(DISK_PATH, "sync-gate-reset")


def _runtime():
    from mining_dashboard.service import data_service

    return data_service


def chain_synced(sync):
    """
    A node's raw "fully synced" verdict for the #35 sync gate and the #234 clearnet transition,
    both one-way. Only an explicit reading counts: the node answered this cycle
    (``reachable is True``) and said it isn't syncing (``is_syncing is False``). An empty,
    partial or unreachable result is not synced (#2472).

    When the reading carries monerod's own ``synchronized`` flag (the RPC path), that flag
    must be True too. A monerod that has just restarted and has no peers yet reports
    ``target_height: 0`` with ``synchronized: false``, which the client maps to "not syncing".
    Before this check the gate took that as synced and released the miner on a chain that had
    never synced. A reading without the key (the log/stats fallback, Tari) has no such verdict to wait on.
    """
    return (
        sync.get("reachable") is True
        and sync.get("is_syncing") is False
        and sync.get("synchronized", True) is True
    )


class DataGateMixin:
    async def _apply_worker_rejection(self, monero_down, tari_down=False):
        """Stop the proxy on a debounced required-node outage; readmit only after
        every required node is confirmed healthy. Tari is required by default;
        opting out preserves Monero mining through a Tari-only outage.

        Act only on transitions. Failed Docker operations leave the flag unchanged
        so the next cycle retries; repeat operations are safe (HTTP 304).
        """
        required_down = monero_down or (_runtime().TARI_REQUIRED and tari_down)
        if required_down:
            if not self.workers_rejected:
                logger.warning(
                    f"Required node unreachable — stopping {_runtime().REJECT_WORKERS_CONTAINER} so workers "
                    f"fail over to their backup pools."
                )
                if await self.docker_control.stop(_runtime().REJECT_WORKERS_CONTAINER):
                    self.workers_rejected = True
            return

        # Not-down is insufficient after a dashboard restart or during recovery.
        recovered = self.monero_health.healthy and (
            not _runtime().TARI_REQUIRED or self.tari_health.healthy
        )
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
                # The release is now earned on the chains this machine dials; the marker (a restore's
                # or an apply's node change) has done its job.
                try:
                    os.remove(_runtime().SYNC_GATE_RESET_PATH)
                except FileNotFoundError:
                    pass
                except OSError as e:
                    logger.warning(
                        f"Could not remove the sync-gate marker (restore or node change): {e}"
                    )
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
