import copy
import os
import time

from mining_dashboard.config import config
from mining_dashboard.service import host_resources
from mining_dashboard.service.network.egress import egress_posture_from_config
from mining_dashboard.service.network.topology import topology_from_config
from mining_dashboard.version import resolve_version
from mining_dashboard.web.miner_connection import stratum_state
from mining_dashboard.web.views import charts, views, xvb_views
from mining_dashboard.web.views.header import dashboard_onion, host_display_addr

KV_KEYS = (
    "payout_wallet_changed_ts",
    "payout_wallet_prev8",
    "payout_wallet",
)


def _copy(value):
    return copy.deepcopy(value)


def freeze(value):
    return _copy(value)


def collect(data, state):
    now = time.time()
    monero_payouts = state.get_payouts("monero") if config.PAYOUT_CONFIRM_ENABLED else []
    tari_payouts = state.get_payouts("tari") if config.TARI_PAYOUT_CONFIRM_ENABLED else []
    changed = state.get_kv("payout_wallet_changed_ts")
    kv = {"payout_wallet_changed_ts": changed}
    try:
        changed_at = float(changed or 0)
    except (TypeError, ValueError):
        changed_at = 0
    if changed_at and now - changed_at < xvb_views.WALLET_CHANGED_BADGE_SEC:
        previous = state.get_kv("payout_wallet_prev8")
        current = state.get_kv("payout_wallet")
        kv["payout_wallet_prev8"] = (previous or "")[:8]
        kv["payout_wallet"] = (current or "")[:8]
    monero_local = xvb_views.monero_is_local()
    tari_local = xvb_views.tari_is_local()
    endpoints = [
        {"name": entry["name"], "watts": entry.get("watts")}
        for entry in config.current_worker_endpoints()
    ]
    return _copy(
        {
            "storage": {
                "share_stats": state.get_share_stats(),
                "raffle_wins": state.get_raffle_wins(),
                "payouts": {"monero": monero_payouts, "tari": tari_payouts},
                "db_healthy": state.is_db_healthy(),
                "xvb_stats": state.get_xvb_stats(),
                "tiers": state.get_tiers(),
                "xvb_round_stats": state.get_xvb_round_stats(),
                "xvb_reward_estimates": state.get_xvb_reward_estimates(),
                "disk_growth": state.get_disk_growth(),
                "xvb_standby": state.get_xvb_standby(),
                "blocks": state.get_blocks(),
                "xvb_history": state.get_xvb_history(),
                "events": state.get_events(),
                "kv": kv,
            },
            "settings": {
                "now": now,
                "zone": os.environ.get("TZ", ""),
                "payout_confirm_enabled": bool(config.PAYOUT_CONFIRM_ENABLED),
                "tari_payout_confirm_enabled": bool(config.TARI_PAYOUT_CONFIRM_ENABLED),
                "tari_required": bool(config.TARI_REQUIRED),
                "control_enabled": bool(config.DASHBOARD_CONTROL_ENABLED),
                "host_ip": config.HOST_IP,
                "host_addr": host_display_addr(config.HOST_IP),
                "dashboard_onion": dashboard_onion(),
                "stratum": stratum_state(),
                "version": resolve_version(),
                "os_update": views.read_os_update_state(),
                "last_update": views.format_time_abs((data or {}).get("timestamp") or now),
                "egress": egress_posture_from_config(),
                "topology": topology_from_config(),
                "update_interval": charts.UPDATE_INTERVAL,
                "badge_settings": {
                    "disk_warn_percent": xvb_views.DISK_WARN_PERCENT,
                    "disk_critical_percent": xvb_views.DISK_CRITICAL_PERCENT,
                    "low_ram_available_gb": xvb_views.LOW_RAM_AVAILABLE_GB,
                    "low_ram_floor_gb": xvb_views.low_ram_floor_gb(monero_local, tari_local),
                    "monero_local": monero_local,
                    "tari_local": tari_local,
                },
                "energy_config": config.DASHBOARD_ENERGY,
                "worker_endpoints": endpoints,
                "resource_max_age": host_resources._MAX_AGE,
            },
        }
    )


class FrozenState:
    def __init__(self, snapshot):
        self._values = _copy(snapshot["storage"])

    def _get(self, name):
        return _copy(self._values[name])

    def get_share_stats(self):
        return self._get("share_stats")

    def get_raffle_wins(self, since=0.0):
        return _since(self._get("raffle_wins"), since)

    def get_payouts(self, chain=None):
        payouts = self._get("payouts")
        if chain is not None:
            return payouts.get(chain, [])
        return sorted(
            [row for rows in payouts.values() for row in rows],
            key=lambda row: row.get("ts", 0),
            reverse=True,
        )

    def is_db_healthy(self):
        return bool(self._values["db_healthy"])

    def get_xvb_stats(self):
        return self._get("xvb_stats")

    def get_tiers(self):
        return self._get("tiers")

    def get_xvb_round_stats(self):
        return self._get("xvb_round_stats")

    def get_xvb_reward_estimates(self):
        return self._get("xvb_reward_estimates")

    def get_disk_growth(self, since=0.0):
        return _since(self._get("disk_growth"), since)

    def get_xvb_standby(self):
        return self._get("xvb_standby")

    def get_blocks(self, since=0.0):
        return _since(self._get("blocks"), since)

    def get_xvb_history(self, since=0.0):
        return _since(self._get("xvb_history"), since)

    def get_events(self):
        return self._get("events")

    def get_kv(self, key):
        if key not in KV_KEYS:
            raise KeyError(key)
        return self._get("kv").get(key)


def _since(rows, since):
    return rows if not since else [row for row in rows if row.get("ts", 0) >= since]
