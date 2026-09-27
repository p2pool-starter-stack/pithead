import json
import logging
from datetime import UTC, datetime

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


def _epoch(ts: str | None) -> float | None:
    """Docker's RFC 3339 UTC timestamp (nanoseconds, ``Z``) as epoch seconds, or ``None``."""
    try:
        return datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=UTC).timestamp()
    except (TypeError, ValueError):
        return None


async def get_container_health():
    """
    Per-container restart/health snapshot via the READ-ONLY Docker socket proxy (#337).

    Inspects each stack container (``GET /containers/<name>/json`` — the read proxy's
    CONTAINERS=1 ruleset allows it, see docker-compose.yml `docker-proxy`) and returns
    ``{name: {"running", "restarting", "restart_count", "health", "unsupervised", "exit_code",
    "held_since_boot"}}``. ``health`` is
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
                    "held_since_boot": bool(
                        boot is not None
                        and (started := _epoch(state.get("StartedAt"))) is not None
                        and started < boot
                    ),
                }
    except Exception as e:
        logger.debug("Container health sweep failed: %s", e)
    return states
