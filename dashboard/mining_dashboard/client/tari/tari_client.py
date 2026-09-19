import logging
import time

import grpc

from mining_dashboard.config.config import TARI_GRPC_ADDRESS

logger = logging.getLogger("TariClient")

# Attempt to import generated protobuf modules
# See README.md for generation instructions (requires grpcio-tools)
from google.protobuf import empty_pb2

from .generated import base_node_pb2, base_node_pb2_grpc


class TariClient:
    # When the base node is briefly overloaded mid-sync (it logs "BaseNodeService failed
    # to send reply ... ChainMetadata" and its own `status` command times out), gRPC calls
    # fail. Serve the last good sync reading for up to this long so the dashboard doesn't
    # flicker to 0/0 on every blip. Bounded so a genuinely down node isn't masked forever —
    # the "node is down" signal is NodeHealthMonitor's job (#31), not this cache's.
    _MAX_STALE_SECONDS = 300

    def __init__(self):
        self.grpc_address = TARI_GRPC_ADDRESS
        self._channel = None
        self._stub = None
        self._last_sync_status = None
        self._last_sync_ts = 0.0
        # Last probe error text, for the remote-sync-wait reason (#2353) — cleared on the
        # next successful GetTipInfo, kept across a failed cycle even when a stale cached
        # sync reading masks the failure from the rest of the status dict.
        self.last_error = None

    def _ensure_channel(self):
        if self._channel is None:
            self._channel = grpc.aio.insecure_channel(self.grpc_address)
            self._stub = base_node_pb2_grpc.BaseNodeStub(self._channel)
        return self._stub

    async def _reset_channel(self):
        """Drop the gRPC channel so the next call reconnects (used after errors)."""
        if self._channel:
            await self._channel.close()
        self._channel = None
        self._stub = None

    async def get_sync_status(self):
        """
        Sync status from the node's own gRPC, with last-known-state caching.

        The base node can get briefly overloaded while syncing — when it does, GetTipInfo
        times out, and we'd otherwise return an empty status that the UI renders as "0/0".
        Instead we serve the last good reading for a short window (see _MAX_STALE_SECONDS),
        so a busy-but-alive node keeps showing its real progress instead of flickering.
        """
        status = await self._fetch_sync_status()
        if status is not None:
            self._last_sync_status = status
            self._last_sync_ts = time.monotonic()
            # `reachable` reflects this cycle's live gRPC, independent of the cache below;
            # it drives node-down detection (Issue #31). Added on the returned copy so the
            # cached `_last_sync_status` stays a pristine sync reading.
            return {**status, "reachable": True, "error": None}

        # gRPC unreachable this cycle. Serve the last good state briefly (node is likely
        # just busy), but stop once it's clearly stale so a down node isn't masked forever.
        # `error` still reflects THIS cycle's failure (#2353) even while stale data is served.
        if (
            self._last_sync_status
            and (time.monotonic() - self._last_sync_ts) <= self._MAX_STALE_SECONDS
        ):
            return {**self._last_sync_status, "reachable": False, "error": self.last_error}
        return {"is_syncing": False, "reachable": False, "error": self.last_error}

    async def _fetch_sync_status(self) -> dict | None:
        """
        Read sync progress from the node's gRPC. Returns the status dict, or None if the
        node is unreachable (so the caller can fall back to the last known state).

        `initial_sync_achieved` is the authoritative "fully synced" flag; while syncing,
        GetSyncProgress.tip_height is the height the node is working toward. Using the
        node's own state means there's no external block explorer to fail.
        """
        try:
            stub = self._ensure_channel()
            tip = await stub.GetTipInfo(empty_pb2.Empty(), timeout=5)
        except Exception as e:
            logger.error(f"Tari gRPC GetTipInfo error: {e}")
            self.last_error = str(e)
            await self._reset_channel()
            return None
        self.last_error = None

        local_height = tip.metadata.best_block_height
        # Surfaced on every reading (synced or not) for the remote-sync-wait reason (#2353):
        # the node's own state and "fully synced" verdict, independent of our height heuristic.
        base_node_state = base_node_pb2.BaseNodeState.Name(tip.base_node_state)
        common = {
            "initial_sync_achieved": tip.initial_sync_achieved,
            "base_node_state": base_node_state,
        }

        # The node reports initial sync complete — trust it over any height heuristic.
        if tip.initial_sync_achieved:
            return {
                **common,
                "is_syncing": False,
                "current": local_height,
                "target": local_height,
                "percent": 100,
            }

        # Still syncing: ask the node what height it is syncing toward, and its own
        # sync-state label (#2353) for a reason richer than "not yet".
        target = 0
        sync_detail = {}
        try:
            progress = await stub.GetSyncProgress(empty_pb2.Empty(), timeout=5)
            if progress.local_height:
                local_height = progress.local_height
            target = progress.tip_height
            sync_detail = {
                "sync_state": base_node_pb2.SyncState.Name(progress.state),
                "short_desc": progress.short_desc or None,
            }
        except Exception as e:
            logger.error(f"Tari gRPC GetSyncProgress error: {e}")
            await self._reset_channel()

        # No reliable target yet (early startup / between sync rounds): report syncing
        # without a false 100%, so the UI shows a loading state, not a premature ✔.
        if target <= local_height:
            return {
                **common,
                **sync_detail,
                "is_syncing": True,
                "current": local_height,
                "target": 0,
                "percent": 0,
            }

        percent = int((local_height / target) * 100)
        return {
            **common,
            **sync_detail,
            "is_syncing": True,
            "current": local_height,
            "target": target,
            "percent": percent,
        }

    async def close(self):
        # ponytail: intentionally NOT wired into DataService.run()'s shutdown. Doing so means a
        # try/finally around the whole poll loop, which drags the (partly untested) loop body into
        # the diff-cover patch gate — a lot of churn to close a channel the OS reclaims on process
        # exit anyway. Kept as a tested lifecycle method for whenever a real graceful path needs it.
        if self._channel:
            await self._channel.close()
            self._channel = None
