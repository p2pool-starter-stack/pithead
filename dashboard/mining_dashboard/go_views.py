import os
import time
from dataclasses import asdict, is_dataclass

from mining_dashboard.config import config

SERIES_FIELDS = {
    "build_share_stats": "share_stats",
    "_window_reject_pct": "reject_pct_24h",
    "build_blocks": "blocks",
    "build_payouts": "payouts",
    "build_disk_growth": "disk_growth",
    "build_xvb_history": "xvb_history",
    "build_hashrate": "hashrate",
    "build_cadence": "cadence",
}


def _args(name, args):
    args = list(args)
    if name == "build_payouts":
        state = args[0]
        args[0] = {
            chain: list(state.get_payouts(chain)) if state is not None and enabled else []
            for chain, enabled in (
                ("monero", config.PAYOUT_CONFIRM_ENABLED),
                ("tari", config.TARI_PAYOUT_CONFIRM_ENABLED),
            )
        }
    elif name in ("build_hashrate", "build_cadence"):
        args[0] = asdict(args[0]) if is_dataclass(args[0]) else vars(args[0])
    else:
        args[0] = list(args[0])
    return args


def builders(sections, captured):
    result = {name: (lambda *_args, value=value: value) for name, value in sections.items()}
    for name, field in SERIES_FIELDS.items():

        def capture(*args, operation=name, target=field):
            captured[target] = {
                "operation": operation,
                "args": _args(operation, args),
                "now": time.time(),
                "zone": os.environ.get("TZ", ""),
            }

        result[name] = capture
    return result
