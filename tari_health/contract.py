"""Turn low-level Tari observations into an honest dashboard health state.

READY is a transport/channel state.  It is deliberately not treated as node
health: a reachable node can still be forked, stale, or peerless.
"""

from dataclasses import dataclass
from enum import Enum


class Health(str, Enum):
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    UNHEALTHY = "unhealthy"
    UNKNOWN = "unknown"


@dataclass(frozen=True)
class TariObservation:
    process_running: bool | None
    channel_ready: bool | None
    node_height: int | None
    network_height: int | None
    peer_count: int | None
    rejected_blocks: int = 0
    bans: int = 0
    observed_at: str | None = None


def evaluate(observation: TariObservation, *, max_lag: int = 12) -> Health:
    """Evaluate node health, failing closed when required evidence is absent.

    ``max_lag`` is a policy threshold, not a claim about Tari consensus.  A
    non-running process, fork/rejection signal, or no peers is unhealthy.  A
    reachable node with an unknown comparison height is unknown, never green.
    """
    if max_lag < 0:
        raise ValueError("max_lag must be non-negative")
    if observation.process_running is False or observation.channel_ready is False:
        return Health.UNHEALTHY
    if observation.rejected_blocks > 0 or observation.bans > 0:
        return Health.UNHEALTHY
    required = (observation.process_running, observation.channel_ready,
                observation.node_height, observation.network_height,
                observation.peer_count)
    if any(value is None for value in required):
        return Health.UNKNOWN
    if observation.peer_count == 0:
        return Health.UNHEALTHY
    lag = observation.network_height - observation.node_height
    if lag < 0:
        return Health.UNKNOWN
    if lag > max_lag:
        return Health.UNHEALTHY
    return Health.HEALTHY

