"""Stack topology (#170): every node and edge of the stack's wiring for the topology panel.

The same config knobs as the egress posture in ``egress.py``, drawn as a graph. The summary is the
posture's, verbatim, so the panel and the egress list can never disagree about a leak.
"""

from mining_dashboard.config import config
from mining_dashboard.service.network.egress import (
    _notify_route,
    _shared_knobs,
    _xvb_route,
    _xvb_standby_route,
    compute_egress_posture,
)
from mining_dashboard.service.network.topology_graph import (
    CLEARNET,
    INACTIVE,
    INCOMING,
    LOCAL,
    TOR,
    edge,
    ext_node,
    node_route,
    topology_nodes,
)


def compute_topology(
    *,
    firewall,
    p2pool_clearnet,
    xvb_enabled,
    xvb_tor,
    monero_clearnet_sync,
    tari_clearnet_sync,
    monero_route,
    tari_route=LOCAL,
    tari_enabled=True,
    healthchecks_enabled,
    telegram_enabled,
    price_feed_enabled=False,
    notify_sinks_enabled=False,
    notify_tor=True,
    notify_sinks_private=False,
    xvb_standby_source="",
    tor_auto_heal=False,
    local_miner_enabled=False,
):
    """Pure derivation of the stack topology. ``kind`` is ``ingress``, ``egress``, ``p2p``
    (bidirectional — egress *and* onion ingress for the P2P daemons), or ``internal`` (host-only
    plumbing, hidden until expanded). The summary is shared verbatim with the egress list.
    """
    posture = compute_egress_posture(
        firewall=firewall,
        p2pool_clearnet=p2pool_clearnet,
        xvb_enabled=xvb_enabled,
        xvb_tor=xvb_tor,
        monero_clearnet_sync=monero_clearnet_sync,
        tari_clearnet_sync=tari_clearnet_sync,
        monero_route=monero_route,
        tari_route=tari_route,
        tari_enabled=tari_enabled,
        healthchecks_enabled=healthchecks_enabled,
        telegram_enabled=telegram_enabled,
        price_feed_enabled=price_feed_enabled,
        notify_sinks_enabled=notify_sinks_enabled,
        notify_tor=notify_tor,
        notify_sinks_private=notify_sinks_private,
        xvb_standby_source=xvb_standby_source,
        tor_auto_heal=tor_auto_heal,
    )
    xvb = _xvb_route(xvb_enabled, xvb_tor)
    sinks = _notify_route(notify_sinks_enabled, notify_tor, notify_sinks_private)
    standby = _xvb_standby_route(xvb_standby_source)
    sidechain = CLEARNET if p2pool_clearnet else TOR
    monero_kind = "internal" if monero_route == LOCAL else "egress"
    tari_kind = "internal" if tari_route == LOCAL else "egress"

    edges = [
        edge("rigs", "xmrig-proxy", INCOMING, f"stratum :{config.STRATUM_PORT}", "ingress"),
        edge("browser", "caddy", INCOMING, "https :443", "ingress"),
        edge("p2pool", ext_node(sidechain), sidechain, "sidechain P2P", "p2p"),
        *([edge("monerod", "tor", TOR, "Monero P2P + tx", "p2p")] if monero_route == LOCAL else []),
        *(
            [edge("tari", "tor", TOR, "Tari P2P", "p2p")]
            if tari_enabled and tari_route == LOCAL
            else []
        ),
        edge("xmrig-proxy", ext_node(xvb), xvb, "XvB donation", "egress"),
        edge("dashboard", "tor", TOR, "update check", "egress"),
        edge("dashboard", "tor", TOR if xvb_enabled else INACTIVE, "XvB stats", "egress"),
        edge("dashboard", "tor", TOR if tor_auto_heal else INACTIVE, "Tor egress probe", "egress"),
        edge(
            "dashboard",
            "tor",
            TOR if healthchecks_enabled else INACTIVE,
            "Healthchecks ping",
            "egress",
        ),
        edge(
            "dashboard",
            "tor",
            TOR if telegram_enabled else INACTIVE,
            "Telegram bot",
            "egress",
        ),
        edge(
            "dashboard",
            "tor",
            TOR if price_feed_enabled else INACTIVE,
            "price feed",
            "egress",
        ),
        *(
            [edge("dashboard", ext_node(sinks), sinks, "alert sinks", "egress")]
            if sinks != LOCAL
            else []
        ),
        *(
            [edge("dashboard", ext_node(standby), standby, "XvB standby", "egress")]
            if standby != LOCAL
            else []
        ),
        edge("tor", "internet", TOR, "SOCKS + onion circuits", "p2p"),
        edge("xmrig-proxy", "p2pool", LOCAL, "upstream pool", "internal"),
        edge("p2pool", "monerod", monero_route, "RPC / ZMQ", monero_kind),
        *(
            [edge("p2pool", "tari", tari_route, "gRPC merge-mine", tari_kind)]
            if tari_enabled
            else []
        ),
        edge("caddy", "dashboard", LOCAL, "reverse-proxy :8000", "internal"),
        edge("dashboard", "monerod", monero_route, "get_info RPC", monero_kind),
        edge("dashboard", "xmrig-proxy", LOCAL, "proxy API", "internal"),
        *([edge("dashboard", "tari", tari_route, "gRPC", tari_kind)] if tari_enabled else []),
        edge("dashboard", "docker", LOCAL, "container API", "internal"),
    ]
    if local_miner_enabled:
        edges.append(edge("local-miner", "xmrig-proxy", LOCAL, "local stratum", "ingress"))
    if monero_clearnet_sync and monero_route == LOCAL:
        edges.append(edge("monerod", "internet", CLEARNET, "clearnet IBD", "egress"))
    if tari_enabled and tari_clearnet_sync and tari_route == LOCAL:
        edges.append(edge("tari", "internet", CLEARNET, "clearnet IBD", "egress"))

    for link in edges:
        if link["route"] != CLEARNET:
            continue
        if link["from"] != "dashboard" and firewall:
            link["blocked_by_firewall"] = True
        else:
            link["leak"] = True

    nodes = topology_nodes(
        monero_route=monero_route,
        tari_route=tari_route,
        tari_enabled=tari_enabled,
        local_miner_enabled=local_miner_enabled,
    )
    return {"nodes": nodes, "edges": edges, "summary": posture["summary"]}


def topology_from_config():
    """Build the topology from the live dashboard config (values pithead rendered into the env)."""
    return compute_topology(
        firewall=config.TOR_EGRESS_FIREWALL,
        p2pool_clearnet=config.P2POOL_CLEARNET,
        xvb_enabled=config.ENABLE_XVB,
        xvb_tor=config.XVB_TOR_ENABLED,
        monero_clearnet_sync=config.MONERO_CLEARNET_SYNC,
        tari_clearnet_sync=config.TARI_CLEARNET_SYNC,
        monero_route=node_route(config.MONERO_NODE_HOST, is_local=config.monero_is_local()),
        tari_route=node_route(config.TARI_GRPC_ADDRESS, is_local=config.tari_is_local()),
        tari_enabled=config.TARI_MODE != "off",
        healthchecks_enabled=bool(config.HEALTHCHECKS_PING_URL),
        telegram_enabled=config.TELEGRAM_ENABLED,
        price_feed_enabled=config.DASHBOARD_ENERGY["price_feed"],
        xvb_standby_source=config.XVB_STANDBY_SOURCE,
        local_miner_enabled=config.local_miner_enabled(),
        **_shared_knobs(),
    )
