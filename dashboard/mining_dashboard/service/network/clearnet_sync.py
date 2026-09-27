import json
import logging
import os
import tempfile
import uuid

from mining_dashboard.config import config
from mining_dashboard.service import control_service, request_spool

logger = logging.getLogger("ClearnetSync")

# Restart timeouts for the clearnet→Tor flip (#234). A daemon can be slow to stop (Tari took >10s
# and was SIGKILL'd), and Docker holds the stop request open until the container is down — so the
# HTTP timeout MUST exceed the stop deadline, or the stop call aborts early, reports failure, and
# (with the old `stop and start`) skipped the start entirely, leaving the daemon down.
_RESTART_STOP_TIMEOUT = 30  # seconds Docker waits (SIGTERM → SIGKILL) for the daemon to stop
_RESTART_HTTP_TIMEOUT = (
    60  # HTTP timeout for the stop/start calls; must exceed _RESTART_STOP_TIMEOUT
)


class ClearnetSyncSupervisor:
    """Auto-transition a clearnet-syncing node back to Tor once it's synced (#183/#234).

    When ``monero.clearnet_initial_sync`` / ``tari.clearnet_initial_sync`` is on, the daemon does
    its initial block download over CLEARNET (fast) instead of Tor — briefly exposing this host's IP
    to that chain's P2P network. This supervisor watches the per-chain "synced" signal the data loop
    already computes; the first time a clearnet node reports synced it drops a persistent marker in
    the shared ``state_dir`` and restarts the container. The daemon's entrypoint, seeing the marker,
    comes back up Tor-only — and stays there across restarts/``apply`` (a reboot can't silently
    re-expose it). ``pithead apply`` removes the marker while the configured flag is off, re-arming.

    Direction is one-way: it only ever moves a node TOWARD Tor. Fail-safe: the marker is written
    BEFORE the restart (so the restarted container is guaranteed to pick Tor), and a failed restart
    is retried on the next cycle rather than left half-done — a node is never silently stranded on
    clearnet.

    The supervisor is intentionally passive about chains whose flag is off; it only acts on the ones
    the operator opted into.
    """

    def __init__(self, state_dir, docker_control, *, on_transition=None):
        self.state_dir = state_dir
        self.docker_control = docker_control
        # Called as on_transition(name, ok) after a flip attempt — lets the UI surface the event.
        self.on_transition = on_transition
        # A marker alone means "Tor requested"; it does not prove the host closed its firewall
        # exception or that the restart succeeded. Retry that pending work after any restart.
        self._flipped = {
            n for n in ("monero", "tari") if os.path.isfile(self.marker_path(n) + ".tor")
        }
        self._pending = {}

    def marker_path(self, name):
        return os.path.join(self.state_dir, f"{name}.synced")

    def _marker_exists(self, name) -> bool:
        try:
            return os.path.isfile(self.marker_path(name))
        except OSError:
            return False

    def _write_marker(self, name) -> bool:
        """Persist the per-chain transition marker. Returns True on success."""
        try:
            os.makedirs(self.state_dir, exist_ok=True)
            with open(self.marker_path(name), "w") as fh:
                fh.write("clearnet initial sync complete; Tor transition pending (#2678)\n")
            return True
        except OSError as exc:
            logger.error(
                "%s: could not write Tor-resync marker at %s: %s", name, self.marker_path(name), exc
            )
            return False

    def _write_completion(self, name) -> bool:
        try:
            with open(self.marker_path(name) + ".tor", "w") as fh:
                fh.write("Tor restart completed after host firewall verification\n")
            return True
        except OSError as exc:
            logger.error("%s: Tor restart succeeded but completion marker failed: %s", name, exc)
            return False

    async def maybe_transition(self, name, container, flag_on, synced):
        """Drive one chain's clearnet→Tor transition. Idempotent; call every poll cycle.

        Returns True iff the node is CURRENTLY exposed on clearnet (still syncing, or a flip that
        hasn't succeeded yet) — the caller uses this to surface the "clearnet active" banner.
        """
        if not flag_on:
            self._flipped.discard(name)
            self._pending.pop(name, None)
            return False
        # Already on Tor: a prior run transitioned it, or we did this run.
        if name in self._flipped:
            return False
        if not synced and not self._marker_exists(name):
            return True  # still doing its clearnet initial sync — exposed

        # Synced over clearnet → commit to Tor. Persist the marker FIRST: it's what makes the
        # restarted container (and every future start, incl. after a reboot) render Tor. If we can't
        # persist it, do NOT restart — a restart without the marker would just re-render clearnet,
        # and a reboot would re-expose the node. Stay exposed and retry next cycle instead.
        if not self._marker_exists(name) and not self._write_marker(name):
            return True
        rid = self._pending.get(name)
        if rid is None:
            try:
                rid = self._request_refresh(name)
            except OSError as exc:
                logger.error("%s: could not request host firewall refresh: %s", name, exc)
                return True
            self._pending[name] = rid
            return True
        result = control_service.result(rid)
        if result is None:
            return True
        self._pending.pop(name, None)
        if result.get("status") != "applied" or result.get("chain") != name:
            logger.error("%s: host firewall refresh failed; retrying before Tor restart", name)
            if self.on_transition is not None:
                try:
                    self.on_transition(name, False)
                except Exception:
                    logger.debug("on_transition callback raised", exc_info=True)
            return True
        logger.warning(
            "%s: CLEARNET initial sync complete — switching %s back to Tor (#234).", name, container
        )
        # Stop with a generous window + an HTTP timeout that OUTLASTS it, then ALWAYS start. The old
        # `stop and start` left a slow-stopping daemon down: when stop's HTTP call timed out before
        # the container finished stopping, `and` short-circuited and start was never called (#234:
        # Tari took >5s to stop and never came back). `ok` is now the START result — the container
        # must end up running; a stop hiccup can no longer skip the start.
        await self.docker_control.stop(
            container, stop_timeout=_RESTART_STOP_TIMEOUT, request_timeout=_RESTART_HTTP_TIMEOUT
        )
        ok = await self.docker_control.start(container, request_timeout=_RESTART_HTTP_TIMEOUT)
        if ok:
            ok = self._write_completion(name)
            if ok:
                self._flipped.add(name)
                logger.info("%s: %s restarted — now Tor-only.", name, container)
        else:
            # Restart failed: do NOT mark flipped, so we retry next cycle. The marker is already on
            # disk, so any start (this retry, a manual restart, a reboot) brings the node up on Tor.
            logger.error(
                "%s: restart of %s onto Tor failed — will retry next cycle (the marker is "
                "set, so any restart comes up Tor-only).",
                name,
                container,
            )
        if self.on_transition is not None:
            try:
                self.on_transition(name, ok)
            except Exception:  # never let a UI callback break the supervisor
                logger.debug("on_transition callback raised", exc_info=True)
        return not ok

    def _request_refresh(self, name):
        rid = str(uuid.uuid4())
        if config.DASHBOARD_CONTROL_ENABLED:
            return request_spool.write(
                {"id": rid, "action": "egress-sync", "actor": "sync-supervisor", "chain": name}
            )
        request_dir = os.path.join(self.state_dir, "requests")
        os.makedirs(request_dir, exist_ok=True)
        path = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", dir=request_dir, prefix=f".{rid}.", delete=False
            ) as fh:
                path = fh.name
                json.dump({"id": rid, "action": "egress-sync", "chain": name}, fh)
            os.replace(path, os.path.join(request_dir, f"{rid}.json"))
        except BaseException:
            if path is not None and os.path.exists(path):
                os.unlink(path)
            raise
        return rid
