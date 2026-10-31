import logging
import time
from urllib.parse import urlsplit

from mining_dashboard.config import config

logger = logging.getLogger("SyncStatus")


def node_address(address: str) -> str | None:
    try:
        parsed = urlsplit(address if "://" in address else "//" + address)
        host = parsed.hostname
        if not host:
            return None
        host = f"[{host}]" if ":" in host else host
        return f"{host}:{parsed.port}" if parsed.port else host
    except ValueError:
        return None


class SyncStatus:
    def __init__(self, clock=time.monotonic, wall_clock=time.time):
        self.clock = clock
        self.wall_clock = wall_clock
        self.waits = {}
        self.previous = {}

    def observe(self, service, monero, tari):
        now = self.clock()
        chains = {}
        for name, raw, local, address in (
            ("monero", monero, config.monero_is_local(), config.MONERO_RPC_URL),
            ("tari", tari, config.tari_is_local(), config.TARI_GRPC_ADDRESS),
        ):
            if name == "tari" and config.TARI_MODE == "off":
                continue
            reachable = raw.get("reachable")
            synced = raw.get("initial_sync_achieved") if name == "tari" else raw.get("synchronized")
            if synced is None and reachable is True and type(raw.get("is_syncing")) is bool:
                synced = not raw["is_syncing"]
            waiting = reachable is not True or synced is not True
            identity = node_address(address)
            key = (name, identity)
            if waiting:
                self.waits.setdefault(key, now)
            else:
                self.waits.pop(key, None)
            monitor = getattr(service, f"{name}_health")
            since = monitor._reachable_since
            recovery = (
                max(0, monitor.recovery_after - (monitor._clock() - since))
                if since is not None and not monitor.healthy
                else None
            )
            chain = {
                "local": local,
                "node": identity if local is False else None,
                "reachable": reachable,
                "synced": synced,
                "healthy": monitor.healthy,
                "down": raw.get("down"),
                "health": raw.get("health"),
                "base_node_state": raw.get("base_node_state"),
                "sync_state": raw.get("sync_state"),
                "initializing": raw.get("initializing"),
                "initial_sync_achieved": raw.get("initial_sync_achieved"),
                "error": raw.get("error")
                or ("RPC probe failed; no live response" if reachable is False else None),
                "wait_seconds": max(0, now - self.waits[key]) if waiting else 0,
                "recovery_remaining": recovery,
                "service_recreated": None,
            }
            transition = (
                identity,
                reachable,
                synced,
                chain["base_node_state"],
                chain["sync_state"],
                chain["initializing"],
                chain["error"],
            )
            if local is False and self.previous.get(name) != transition:
                logger.info(
                    "Remote %s sync state changed: reachable=%s synced=%s state=%s initial_sync_achieved=%s error=%s",
                    name,
                    reachable,
                    synced,
                    chain["initializing"] or chain["base_node_state"] or chain["sync_state"],
                    chain["initial_sync_achieved"],
                    chain["error"],
                )
            self.previous[name] = transition
            chains[name] = chain
        return {
            "sampled_at": self.wall_clock(),
            "chains": chains,
            "mining": {
                "released": service.miner_released,
                "held": service.miner_held,
                "workers_rejected": service.workers_rejected,
                "fail_closed": service.fail_closed_held,
            },
        }
