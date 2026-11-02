from mining_dashboard import go_channel
from mining_dashboard.client import rigforge_freshness

REFERENCE_FUNCTIONS = {}
FIELDS = frozenset(
    "generated_at age_sec stale version miner_down power tune health watchdog config config_meta".split()
)
SECTIONS = {
    "power": {"watts", "hs_per_watt"},
    "tune": {"target", "autotune_enabled", "autotune_next"},
    "health": {"governor", "throttling", "board", "hugepages_total"},
    "watchdog": {"enabled", "thermal_hold", "temp_c", "max_temp_c"},
}
META_FIELDS = {"revision", "changed_at", "source", "last_change_id"}


def parse_rigforge(payload, now=None):
    from mining_dashboard.client import xmrig_client

    reply = go_channel.call(
        "fleet",
        {
            "operation": "poll_parse_rigforge",
            "args": [payload, rigforge_freshness.time.time() if now is None else now],
            "envelope": True,
        },
    )
    if reply is None:
        return None
    if not isinstance(reply, dict) or set(reply) != FIELDS:
        raise RuntimeError("native RigForge parser returned invalid fields")
    if any(
        not isinstance(reply[name], dict) or set(reply[name]) != keys
        for name, keys in SECTIONS.items()
    ):
        raise RuntimeError("native RigForge parser returned invalid sections")
    if any(
        type(value) is not bool
        for value in (
            reply["stale"],
            reply["miner_down"],
            reply["tune"]["autotune_enabled"],
            reply["watchdog"]["enabled"],
        )
    ):
        raise RuntimeError("native RigForge parser returned invalid flags")
    if (
        reply["generated_at"] is not None
        and not isinstance(reply["generated_at"], str)
        or reply["age_sec"] is not None
        and (type(reply["age_sec"]) is not int or reply["age_sec"] < 0)
    ):
        raise RuntimeError("native RigForge parser returned invalid freshness")
    config = reply["config"]
    if config is not None and (
        not isinstance(config, dict) or not set(config).issubset(xmrig_client.WORKER_WRITABLE_KEYS)
    ):
        raise RuntimeError("native RigForge parser returned invalid config")
    meta = reply["config_meta"]
    if meta is not None and (
        not isinstance(meta, dict)
        or set(meta) != META_FIELDS
        or any(value is not None and not isinstance(value, str) for value in meta.values())
    ):
        raise RuntimeError("native RigForge parser returned invalid metadata")
    return reply


def install():
    from mining_dashboard.client import xmrig_client
    from mining_dashboard.service import data_helpers
    from mining_dashboard.service.workers import worker_refresh

    REFERENCE_FUNCTIONS.setdefault("parse_rigforge", xmrig_client.parse_rigforge)
    xmrig_client.parse_rigforge = parse_rigforge
    data_helpers.parse_rigforge = parse_rigforge
    worker_refresh.parse_rigforge = parse_rigforge
