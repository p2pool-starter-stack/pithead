import json
import logging
import time
from datetime import datetime

import aiohttp

from mining_dashboard.config.config import DOCKER_PROXY_URL, DOCKER_TIMEOUT
from mining_dashboard.helper.http import bounded_read

logger = logging.getLogger("ContainerCollector")

# Every container the stack defines (docker-compose.yml `container_name:`). Names that don't
# exist on this host — remote mode drops monerod, a disabled profile drops its service — 404
# on inspect and are simply skipped, so this list can stay the full set.
MONITORED_CONTAINERS = (
    "tor",
    "monerod",
    "tari",
    "p2pool",
    "xmrig-proxy",
    "dashboard",
    "docker-proxy",
    "docker-control",
    "caddy",
)


def _host_boot_epoch() -> int | None:
    """The host's boot time (``btime`` in ``/proc/stat``; a container shares the host kernel), or
    ``None`` when unreadable."""
    try:
        with open("/proc/stat") as f:
            for line in f:
                if line.startswith("btime "):
                    return int(line.split()[1])
    except (OSError, ValueError):
        pass
    return None


PEERS_MARKER = "pithead-monero-peers "
# The healthcheck runs every 30 s; an observation older than three runs is stale.
PEERS_FRESH_SEC = 90

_NO_PEERS = {"peers_in": None, "peers_out": None}


def _count(value):
    """A connection count, or None when it is not a plain non-negative integer."""
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def parse_monero_peers(payload, now=None):
    """
    monerod's peer counts from the latest healthcheck run in its inspect payload (#2921).

    The published RPC is restricted and answers 0 for the counts, so the healthcheck reads the
    admin listener on the container's own loopback and prints one ``pithead-monero-peers {...}``
    line, which the engine keeps in ``State.Health.Log``. Returns ``{"peers_in", "peers_out"}``,
    both ``None`` (unavailable, never zero) unless the LAST run is fresh, began after this
    container run started, and carries a well-formed observation. The exit code is not read: the
    healthcheck prints the line and then exits 1 once the node has been peerless past its bound,
    and that run is exactly the reading the peerless verdict needs. A run that failed before
    reading (RPC down, timeout) prints no line.
    """
    now = time.time() if now is None else now
    state = payload.get("State") if isinstance(payload, dict) else None
    health = state.get("Health") if isinstance(state, dict) else None
    log = health.get("Log") if isinstance(health, dict) else None
    started = _epoch(state.get("StartedAt")) if isinstance(state, dict) else None
    if not isinstance(log, list) or not log or started is None or not isinstance(log[-1], dict):
        return dict(_NO_PEERS)
    last = log[-1]
    began, ended = _epoch(last.get("Start")), _epoch(last.get("End"))
    if (
        began is None
        or ended is None
        or began < started
        or ended < began
        or now - ended > PEERS_FRESH_SEC
        or ended - now > 5
    ):
        return dict(_NO_PEERS)
    for line in str(last.get("Output") or "").splitlines():
        if not line.startswith(PEERS_MARKER):
            continue
        try:
            obs = json.loads(line[len(PEERS_MARKER) :])
        except ValueError:
            return dict(_NO_PEERS)
        if not isinstance(obs, dict):
            return dict(_NO_PEERS)
        out, inn = _count(obs.get("outgoing")), _count(obs.get("incoming"))
        if out is None or inn is None:
            return dict(_NO_PEERS)
        return {"peers_in": inn, "peers_out": out}
    return dict(_NO_PEERS)


def _epoch(ts: str | None) -> float | None:
    """Docker's RFC 3339 UTC timestamp (nanoseconds, ``Z``) as epoch seconds, or ``None``."""
    try:
        return datetime.fromisoformat(ts).timestamp()
    except (TypeError, ValueError):
        return None


async def get_container_health():
    """
    Per-container restart/health snapshot via the READ-ONLY Docker socket proxy (#337).

    Inspects each stack container (``GET /containers/<name>/json`` — the read proxy's
    CONTAINERS=1 ruleset allows it, see docker-compose.yml `docker-proxy`) and returns
    ``{name: {"running", "restarting", "restart_count", "health", "unsupervised", "exit_code",
    "held_since_boot", "started_at"}}``. ``started_at`` is ``State.StartedAt`` as epoch seconds
    (``None`` when unreadable). ``health`` is
    ``State.Health.Status`` (never the human "Up 2 hours (unhealthy)" list string) and is
    ``None`` when the container has no healthcheck — no signal, not "unhealthy". A missing
    container (404) or an unreachable proxy skips that name rather than raising, so remote
    mode and a proxy blip never break the data loop.

    ``unsupervised`` is restart policy "no", which pithead sets only on a LAN-access node container of
    a DIY Docker host (#2749): nothing but ``./pithead up`` or pithead-lan-hold.service at boot starts
    it. ``held_since_boot`` is true when it has not started since the host booted (its ``StartedAt``
    is older than the boot), which is the hold after a failed LAN guard rather than a crash.
    """
    # Ensure URL scheme is http for aiohttp, even if env var is tcp://
    base_url = DOCKER_PROXY_URL
    if base_url.startswith("tcp://"):
        base_url = base_url.replace("tcp://", "http://")

    states = {}
    boot = _host_boot_epoch()
    try:
        async with aiohttp.ClientSession() as session:
            for name in MONITORED_CONTAINERS:
                try:
                    async with session.get(
                        f"{base_url}/containers/{name}/json", timeout=DOCKER_TIMEOUT
                    ) as response:
                        if response.status != 200:
                            continue
                        # Bounded (#1360). Lowest trust class of that set — the payload shape is
                        # dictated by our own compose file — but a proxy that misbehaves should
                        # skip one container, not buffer an unbounded body into the data loop.
                        payload = json.loads(
                            await bounded_read(response.content, what=f"{name} inspect")
                        )
                except Exception as e:
                    logger.debug("Container inspect failed for %s: %s", name, e)
                    continue
                state = payload.get("State") or {}
                health = (state.get("Health") or {}).get("Status")
                states[name] = {
                    "running": bool(state.get("Running")),
                    "restarting": bool(state.get("Restarting")),
                    "restart_count": payload.get("RestartCount", 0) or 0,
                    "health": health if health not in ("", "none") else None,
                    "unsupervised": (
                        ((payload.get("HostConfig") or {}).get("RestartPolicy") or {}).get("Name")
                        == "no"
                    ),
                    "exit_code": state.get("ExitCode"),
                    "started_at": _epoch(state.get("StartedAt")),
                    "held_since_boot": bool(
                        boot is not None
                        and (started := _epoch(state.get("StartedAt"))) is not None
                        and started < boot
                    ),
                }
    except Exception as e:
        logger.debug("Container health sweep failed: %s", e)
    return states


async def get_monero_peers():
    """One read-only inspect of monerod through the read proxy, folded by
    :func:`parse_monero_peers`. Any failure (proxy down, no such container, bad body) is the same
    unavailable answer, never a zero. The container start time travels with a successful inspect
    so the health monitor can reset its clocks across a restart between polls."""
    base_url = DOCKER_PROXY_URL.replace("tcp://", "http://", 1)
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                f"{base_url}/containers/monerod/json", timeout=DOCKER_TIMEOUT
            ) as response:
                if response.status != 200:
                    return dict(_NO_PEERS)
                payload = json.loads(await bounded_read(response.content, what="monerod inspect"))
    except Exception as e:
        logger.debug("monerod peers inspect failed: %s", e)
        return dict(_NO_PEERS)
    peers = parse_monero_peers(payload)
    state = payload.get("State") if isinstance(payload, dict) else None
    peers["monero_run_started"] = (
        _epoch(state.get("StartedAt")) if isinstance(state, dict) else None
    )
    return peers
