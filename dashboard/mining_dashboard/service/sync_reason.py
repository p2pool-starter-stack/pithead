"""Sync-status model (#2353).

When ``tari.mode``/``monero.mode`` is remote, "still syncing" from the node's own report
isn't enough to act on: the page waits on a box outside the appliance, with nothing on
screen or in the log to say so. This turns a chain's raw sync-probe result into that
reason, for display on the sync page and for a log line emitted once per change of
state (never once per poll — ``render`` takes the wait duration as an argument
precisely so it plays no part in the change-detection identity of ``RemoteSyncReason``).
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class RemoteSyncReason:
    chain: str  # "Tari" or "Monero" — display/log text only
    address: str
    initial_sync_achieved: bool | None = None
    state: str | None = None  # base_node_state (Tari GetTipInfo) or an analogous label
    short_desc: str | None = None  # GetSyncProgress.short_desc (Tari), when exposed
    error: str | None = None  # the last probe error, if the call failed

    def render(self, waited_seconds: float) -> str:
        prefix = f"Waiting for the remote {self.chain} node at {self.address}"
        waited = _format_wait(waited_seconds)
        if self.error:
            return f"{prefix}: {self.error}, {waited}"
        details = [d for d in (self.state, self.short_desc) if d]
        details.append(
            "initial sync achieved"
            if self.initial_sync_achieved
            else "initial sync not yet achieved"
        )
        return f"{prefix}: {', '.join(details)}, {waited}"


def describe_remote_wait(chain, address, *, is_local, sync_status) -> RemoteSyncReason | None:
    """The reason a remote node is why the sync page waits, or None when it isn't:
    the node is local/disabled (``is_local`` is ``True``/``None``), or it's reachable
    and no longer syncing."""
    if is_local is not False:
        return None
    if sync_status.get("reachable", True) and not sync_status.get("is_syncing", False):
        return None
    return RemoteSyncReason(
        chain=chain,
        address=address,
        initial_sync_achieved=sync_status.get("initial_sync_achieved"),
        state=sync_status.get("base_node_state") or sync_status.get("sync_state"),
        short_desc=sync_status.get("short_desc"),
        error=sync_status.get("error"),
    )


def _format_wait(seconds: float) -> str:
    minutes = int(seconds // 60)
    return f"{minutes} min" if minutes >= 1 else f"{max(int(seconds), 0)} sec"
