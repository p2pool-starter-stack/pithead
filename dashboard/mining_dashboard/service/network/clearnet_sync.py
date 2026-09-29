import json
import logging
import os
import stat
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


def tor_attested(state_dir, name) -> bool | None:
    """A host result must match this transition's marker; dashboard files cannot attest success."""
    try:
        fd = os.open(
            os.path.join(state_dir, f"{name}.synced"), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
        )
        try:
            marker_stat = os.fstat(fd)
            if not stat.S_ISREG(marker_stat.st_mode):
                return None
            marker = os.read(fd, 38).decode().strip()
        finally:
            os.close(fd)
        with open(os.path.join(config.CONTROL_RESULTS_DIR, f"clearnet-{name}-tor.json")) as fh:
            result = json.load(fh)
        return result == {
            "status": "verified",
            "marker": marker,
            "inode": marker_stat.st_ino,
            "ctime_ns": marker_stat.st_ctime_ns,
        }
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None


class ClearnetSyncSupervisor:
    """Auto-transition a clearnet-syncing node back to Tor once it's synced (#183/#234).

    When ``monero.clearnet_initial_sync`` / ``tari.clearnet_initial_sync`` is on, the daemon does
    its initial block download over CLEARNET (fast) instead of Tor — exposing this host's IP
    to that chain's P2P network. This supervisor watches the per-chain "synced" signal the data loop
    already computes; the first time a clearnet node reports synced it drops a persistent marker in
    the shared ``state_dir`` and restarts the container. The daemon's entrypoint, seeing the marker,
    comes back up Tor-only. The host attests completion only after checking live firewall rules and
    daemon configuration. The marker persists across restarts/``apply`` so a reboot cannot re-expose
    it. ``pithead apply`` removes the marker while the configured flag is off, re-arming.

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
        self._flipped = {n for n in ("monero", "tari") if tor_attested(state_dir, n)}
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
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_NONBLOCK
            with os.fdopen(os.open(self.marker_path(name), flags, 0o600), "w") as fh:
                fh.write(f"{uuid.uuid4()}\n")
            return True
        except OSError as exc:
            logger.error(
                "%s: could not write Tor-resync marker at %s: %s", name, self.marker_path(name), exc
            )
            return False

    async def maybe_transition(self, name, container, flag_on, synced):
        """Drive one chain's clearnet→Tor transition. Idempotent; call every poll cycle.

        Returns True while clearnet is active or the Tor transition awaits host verification;
        the caller keeps the transition warning visible until then.
        """
        if not flag_on:
            self._flipped.discard(name)
            self._pending.pop(name, None)
            return False
        if tor_attested(self.state_dir, name):
            if name not in self._flipped and self.on_transition is not None:
                try:
                    self.on_transition(name, True)
                except Exception:
                    logger.debug("on_transition callback raised", exc_info=True)
            self._flipped.add(name)
            self._pending.pop(name, None)
            return False
        self._flipped.discard(name)
        if not synced and not self._marker_exists(name):
            return True  # still doing its clearnet initial sync — exposed

        # Synced over clearnet → commit to Tor. Persist the marker FIRST: it's what makes the
        # restarted container (and every future start, incl. after a reboot) render Tor. If we can't
        # persist it, do NOT restart — a restart without the marker would just re-render clearnet,
        # and a reboot would re-expose the node. Ask the host to close the firewall exemption even
        # when the marker write fails, then keep retrying without claiming completion.
        if not self._marker_exists(name):
            # Even a malformed dashboard-writable marker must trigger the host's forced-close
            # path. The host removes that chain's exemption before rejecting the bad marker.
            self._write_marker(name)
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
        if not self._marker_exists(name):
            return True
        if tor_attested(self.state_dir, name):
            self._flipped.add(name)
            if self.on_transition is not None:
                try:
                    self.on_transition(name, True)
                except Exception:
                    logger.debug("on_transition callback raised", exc_info=True)
            return False
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
            logger.info(
                "%s: %s restarted; awaiting host verification of live Tor config.", name, container
            )
        else:
            # Restart failed: do NOT mark flipped, so we retry next cycle. The marker is already on
            # disk, so any start (this retry, a manual restart, a reboot) brings the node up on Tor.
            logger.error(
                "%s: restart of %s onto Tor failed — will retry next cycle (the marker is "
                "set, so any restart comes up Tor-only).",
                name,
                container,
            )
        if not ok and self.on_transition is not None:
            try:
                self.on_transition(name, ok)
            except Exception:  # never let a UI callback break the supervisor
                logger.debug("on_transition callback raised", exc_info=True)
        return True

    def _request_refresh(self, name):
        rid = str(uuid.uuid4())
        request = {"id": rid, "action": "egress-sync", "chain": name}
        if config.DASHBOARD_CONTROL_ENABLED:
            request["actor"] = "sync-supervisor"
        return request_spool.write(request)
