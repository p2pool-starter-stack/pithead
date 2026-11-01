from mining_dashboard.config import config
from mining_dashboard.helper import utils
from mining_dashboard.service import metrics


def collect(data, state, history=None):
    if history is None:
        history = state.get_history()
    return {
        "latest_data": data or {},
        "history": history,
        "xvb_stats": state.get_xvb_stats() or {},
        "tiers": [
            {"name": name, "threshold": threshold} for name, threshold in state.get_tiers().items()
        ],
        "config": {
            "enable_xvb": metrics.ENABLE_XVB,
            "donation_level": metrics.XVB_DONATION_LEVEL,
            "max_donation_fraction": metrics.XVB_MAX_DONATION_FRACTION,
            "xvb_stats_stale_after_s": utils.XVB_STATS_STALE_AFTER_S,
            "monero_node_host": metrics.MONERO_NODE_HOST,
            "local_monero_host": metrics.LOCAL_MONERO_HOST,
            "monero_prune": metrics.MONERO_PRUNE,
            "tari_mode": config.TARI_MODE,
            "monero_local": metrics.monero_is_local(),
            "tari_local": metrics.tari_is_local(),
        },
        "now": metrics.time.time(),
    }


def restore(value):
    return metrics.Metrics(
        **{
            **value,
            "monero": metrics.SyncMetric(**value["monero"]),
            "tari": metrics.SyncMetric(**value["tari"]),
        }
    )
