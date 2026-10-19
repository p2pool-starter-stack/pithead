import time

# Code-level defaults, not config.json knobs (same convention as the worker-presence debounce):
# a crash loop is >= CRASH_LOOP_RESTARTS restarts within a rolling CRASH_LOOP_WINDOW_SEC; an
# unhealthy verdict needs the healthcheck failing continuously for UNHEALTHY_AFTER_SEC (one
# flapping probe must not page); recovery needs a clean streak of RECOVERY_AFTER_SEC.
CRASH_LOOP_RESTARTS = 3
CRASH_LOOP_WINDOW_SEC = 600
UNHEALTHY_AFTER_SEC = 120
RECOVERY_AFTER_SEC = 120

# ContainerHealthMonitor edge -> alert message template (AlertService formats and sends it).
EDGE_MESSAGES = {
    "crash_loop": "\U0001f534 \U0001f4e6 Container {name} is crash-looping — restarting repeatedly "
    "(OOM or bad config?). Check: docker logs {name}",
    "unhealthy": "\U0001f7e0 \U0001f4e6 Container {name} is running but unhealthy — its healthcheck "
    "keeps failing.",
    # #2749: a LAN-access node on a DIY Docker host runs with restart "no", so these stay down.
    "held": "\U0001f534 \U0001f4e6 Container {name} is down: held since boot because the LAN-only "
    "source rule for its LAN-access ports was not restored (pithead-lan-guard.service failed). "
    "Fix that, then run ./pithead up",
    "exited": "\U0001f534 \U0001f4e6 Container {name} is down: it exited (code {exit_code}) and, "
    "with LAN access on, Docker does not restart it. Run ./pithead up",
    "recovered": "\U0001f7e2 \U0001f4e6 Container {name} recovered.",
}


class ContainerHealthMonitor:
    """
    Per-container, flap-protected crash-loop / unhealthy tracker (#337).

    The alerter needs a stable "monerod is crash-looping / stuck unhealthy / recovered" signal
    from the per-container inspect snapshots (``collector.containers.get_container_health``).
    This is the container analogue of :class:`WorkerPresenceMonitor` — debounced, seed-silent,
    keyed by container name:

    - **Crash loop** — the restart count rose by ``crash_restarts`` within a rolling
      ``crash_window`` (tracked as deltas against a per-name baseline, so it's safe regardless
      of when Docker resets ``RestartCount`` — a *decrease* rebaselines silently
      [TODO: verify upstream — when Docker resets RestartCount]), OR ``restarting`` observed on
      2 consecutive updates. One edge per incident, not one per restart.
    - **Unhealthy** — ``State.Health.Status == "unhealthy"`` continuously for
      ``unhealthy_after``. ``health=None`` (no healthcheck) is no signal, never "unhealthy".
    - **Recovered** — a previously *alerted* container back to running, not restarting, health
      in (None, "healthy") for ``recovery_after``, with no restart inside that window (so a
      slow crash loop can't ping-pong recovered/crash-loop).
    - **Down, unsupervised** (#2749) — a container with restart policy "no" (``unsupervised``: a
      LAN-access node on a DIY Docker host) not running for ``unhealthy_after``. Nothing restarts
      it, so it is an edge: ``held`` when it has not started since boot (its LAN guard failed),
      ``exited`` otherwise. Unlike the rest it fires from a first sighting too: a node held at boot
      is down before the dashboard ever sees it up.
    - **Never an edge**: any other "exited" (not running, not restarting) — the stack stops p2pool
      and xmrig-proxy on purpose (sync gate #35, node-down failover #31) — and a container that
      disappears from the snapshot (profile off, remote mode, proxy down), which is silently
      forgotten so a later return re-baselines.
    - **Silent baseline.** A container's first sighting registers its current state with no
      edge — one already unhealthy at dashboard start seeds as bad without alerting (a restart
      must not replay a stale transition), and its later recovery is silent too (it was never
      alerted).

    :meth:`update` takes this cycle's snapshot dict and returns a list of ``(name, edge)``,
    ``edge`` in ``{"crash_loop", "unhealthy", "held", "exited", "recovered"}``.

    Clock defaults to wall-clock ``time.time``; injectable for deterministic tests.
    """

    def __init__(
        self,
        crash_restarts=CRASH_LOOP_RESTARTS,
        crash_window=CRASH_LOOP_WINDOW_SEC,
        unhealthy_after=UNHEALTHY_AFTER_SEC,
        recovery_after=RECOVERY_AFTER_SEC,
        clock=time.time,
    ):
        self.crash_restarts = crash_restarts
        self.crash_window = crash_window
        self.unhealthy_after = unhealthy_after
        self.recovery_after = recovery_after
        self._clock = clock
        # name -> {state, alerted, count, restart_times, restarting_streak,
        #          unhealthy_since, ok_since}
        #   state           : "ok" | "bad" (the debounced, edge-emitting state)
        #   alerted         : whether the current bad state produced an edge (a seeded-bad
        #                     container recovers silently)
        #   count           : last observed RestartCount (delta baseline)
        #   restart_times   : timestamps of restarts seen inside the rolling window
        #   restarting_streak: consecutive updates with State.Restarting true
        #   unhealthy_since : when the current continuous-unhealthy streak began
        #   ok_since        : when the current continuous-clean streak began
        self._containers = {}

    def is_confirmed_bad(self, name):
        """True only if `name`'s bad state was CONFIRMED by the debounce — a crash loop or a
        continuous-unhealthy streak past ``unhealthy_after`` — i.e. it produced an alert edge
        (``alerted``). A first-sighting silently-seeded baseline (already unhealthy/restarting at
        the monitor's first look) is deliberately NOT confirmed: it skipped the debounce a KNOWN
        container must pass, exactly as it skips the alert. `dashboard.fail_closed`'s miner hold
        (#490) reads this rather than the raw level, so it holds the fleet only on a confirmed,
        non-transient failure. Unknown/never-seen container reads as not bad."""
        c = self._containers.get(name)
        return bool(c and c["state"] == "bad" and c["alerted"])

    def update(self, states, now=None):
        """Feed this cycle's ``{name: state}`` snapshot; return the debounced edges."""
        now = self._clock() if now is None else now
        edges = []

        # Containers no longer in the snapshot (profile off, remote mode, proxy down) are
        # forgotten silently — absence is never an edge; a later return re-baselines.
        for name in list(self._containers):
            if name not in states:
                del self._containers[name]

        for name, s in states.items():
            c = self._containers.get(name)
            if c is None:
                # First sighting — baseline silently, even when already bad.
                bad = s["health"] == "unhealthy" or s["restarting"]
                self._containers[name] = {
                    "state": "bad" if bad else "ok",
                    "alerted": False,
                    "count": s["restart_count"],
                    "restart_times": [],
                    "restarting_streak": 1 if s["restarting"] else 0,
                    "unhealthy_since": now if s["health"] == "unhealthy" else None,
                    "down_since": now if _unsupervised_down(s) else None,
                    "ok_since": None,
                }
            else:
                self._step(name, c, s, now, edges)
        return edges

    def _step(self, name, c, s, now, edges):
        """Debounce a *known* container's snapshot into crash_loop/unhealthy/recovered edges."""
        # Restart-count deltas against the per-name baseline. A decrease means Docker reset the
        # counter (e.g. the container was recreated) — rebaseline silently, drop stale restarts.
        delta = s["restart_count"] - c["count"]
        c["count"] = s["restart_count"]
        if delta < 0:
            c["restart_times"] = []
        elif delta > 0:
            # Cap the per-poll append: past crash_restarts the verdict can't get any worse.
            c["restart_times"].extend([now] * min(delta, self.crash_restarts))
        c["restart_times"] = [t for t in c["restart_times"] if now - t < self.crash_window]

        c["restarting_streak"] = c["restarting_streak"] + 1 if s["restarting"] else 0
        crash = len(c["restart_times"]) >= self.crash_restarts or c["restarting_streak"] >= 2

        # Unhealthy needs the healthcheck failing on a RUNNING container — an exited one (an
        # intentional stop) is no verdict either way, so both streaks reset while it's down.
        if s["health"] == "unhealthy" and s["running"]:
            if c["unhealthy_since"] is None:
                c["unhealthy_since"] = now
        else:
            c["unhealthy_since"] = None
        unhealthy = (
            c["unhealthy_since"] is not None and now - c["unhealthy_since"] >= self.unhealthy_after
        )
        # Debounced like unhealthy, so a recreate during `pithead up` does not page.
        if _unsupervised_down(s):
            if c.get("down_since") is None:
                c["down_since"] = now
        else:
            c["down_since"] = None
        down = c["down_since"] is not None and now - c["down_since"] >= self.unhealthy_after

        clean = s["running"] and not s["restarting"] and s["health"] in (None, "healthy")
        if clean:
            if c["ok_since"] is None:
                c["ok_since"] = now
        else:
            c["ok_since"] = None

        if c["state"] == "ok":
            # One problem edge per incident: whichever verdict lands first flips the state,
            # and nothing more fires until it recovers.
            if crash:
                c["state"] = "bad"
                c["alerted"] = True
                edges.append((name, "crash_loop"))
            elif unhealthy:
                c["state"] = "bad"
                c["alerted"] = True
                edges.append((name, "unhealthy"))
            elif down:
                c["state"] = "bad"
                c["alerted"] = True
                edges.append((name, "held" if s.get("held_since_boot") else "exited"))
        elif (
            clean
            and now - c["ok_since"] >= self.recovery_after
            and not any(now - t < self.recovery_after for t in c["restart_times"])
        ):
            if c["alerted"]:
                edges.append((name, "recovered"))
            c["state"] = "ok"
            c["alerted"] = False


def _unsupervised_down(s):
    """Restart policy "no" and not running: nothing will start it again (#2749)."""
    return bool(s.get("unsupervised")) and not s["running"] and not s["restarting"]
