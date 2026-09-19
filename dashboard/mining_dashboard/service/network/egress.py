"""Egress posture (#170) — for each stack component, its outbound connections and their network
route (Tor / clearnet / incoming / LAN / local / unknown / inactive), plus a privacy roll-up.

Routes are *derived from the live config*, never hardcoded, so the panel can't drift from reality or
lie after a regression — the #160 audit's lesson (``--onion-address`` *looked* like Tor but wasn't).

Two backstops matter for whether a clearnet route is actually an IP leak:

* The **#270 egress firewall** (``DOCKER-USER``, fail-closed) DROPs non-Tor egress from the *container*
  subnet — so a container's clearnet route can't actually leave while it's on.
* It does **not** cover the **host-networked dashboard** (``network_mode: host``), whose own egress
  (XvB stats fetch, update check, Healthchecks ping, Telegram bot, price feed, webhook/ntfy alert
  sinks, #249 XvB standby pull) bypasses ``DOCKER-USER`` entirely. Those rely solely on their SOCKS config — a clearnet
  route there is a real leak regardless of the firewall. (All are Tor-routed by default, so none
  leak.)

The alert sinks (#380) have one more wrinkle: ``notifications.tor: false`` is a LAN carve-out for
self-hosted endpoints Tor exits can't reach. A POST to a private/loopback IP never leaves your
network, so it routes as *local*, not a clearnet leak. Only IP literals can prove that without a
DNS lookup. A hop to a relocatable node takes the same rule via ``topology_graph.node_route``
(#1350), but keeps *LAN* and *unknown* apart instead of collapsing both into clearnet.

So a connection is a *leak* only when its route is clearnet AND it isn't neutralised by a backstop.
"""

import ipaddress
from urllib.parse import urlsplit

from mining_dashboard.config import config
from mining_dashboard.service.network.topology_graph import (  # noqa: F401  (re-exported)
    CLEARNET,
    INACTIVE,
    INCOMING,
    LOCAL,
    TOPOLOGY_NODES,
    TOR,
    UNKNOWN,
    edge,
    ext_node,
    node_route,
    topology_nodes,
)


def _xvb_route(xvb_enabled, xvb_tor):
    if not xvb_enabled:
        return INACTIVE
    return TOR if xvb_tor else CLEARNET


def _notify_route(enabled, tor, private):
    if not enabled:
        return INACTIVE
    if tor:
        return TOR
    return LOCAL if private else CLEARNET


def _xvb_standby_route(source):
    """Route of the #249 backup→primary standby pull, derived from ``xvb.standby.source`` alone.

    Same #160 reasoning as ``_sinks_all_private``: only an IP literal can be *proven* to stay on your
    network without a DNS lookup. So an ``.onion`` or any public/non-private source rides Tor (the
    puller's ``_proxies`` sends it socks5h, like every other dashboard read); a private/loopback IP
    literal is a LAN hop (``local``); an unset source is ``inactive``. A hostname can't be proven
    private, so it routes over Tor — never a silent clearnet beacon. The puller reads this exact
    route (``XvbStandbyPuller._proxies``), so the panel can't disagree with where the pull goes."""
    source = (source or "").strip()
    if not source:
        return INACTIVE
    host = (urlsplit(source).hostname or "").lower()
    if host.endswith(".onion"):
        return TOR
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:  # not an IP literal (a hostname) — unprovable, route over Tor
        return TOR
    return LOCAL if (ip.is_private or ip.is_loopback or ip.is_link_local) else TOR


def _sinks_all_private(urls) -> bool:
    """True when every configured sink URL targets a private/loopback IP literal — the LAN
    carve-out proof. A hostname can't be verified without a DNS lookup (which a pure config
    derivation must never do), so any hostname makes this False."""
    hosts = [urlsplit(u).hostname for u in urls if u and u.strip()]
    if not hosts:
        return False
    for host in hosts:
        if not host:  # malformed URL (no scheme) — unknowable, assume public
            return False
        try:
            if not ipaddress.ip_address(host).is_private:
                return False
        except ValueError:  # not an IP literal — unknowable, assume public
            return False
    return True


def compute_egress_posture(
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
):
    """Pure derivation of the egress posture from config knobs. Returns ``{components, summary}``."""
    xvb = _xvb_route(xvb_enabled, xvb_tor)
    sinks = _notify_route(notify_sinks_enabled, notify_tor, notify_sinks_private)
    standby = _xvb_standby_route(xvb_standby_source)
    monero_component = {
        "name": "monerod",
        "firewalled": monero_route == LOCAL,
        "conns": (
            [{"to": "Monero P2P / tx relay", "route": TOR}]
            if monero_route == LOCAL
            else [{"to": "remote Monero node (get_info RPC)", "route": monero_route}]
        ),
    }
    if monero_clearnet_sync and monero_route == LOCAL:
        monero_component["conns"].append(
            {"to": "initial block download (clearnet sync)", "route": CLEARNET}
        )
    if tari_route == LOCAL:
        tari_conns = [
            {"to": "Tari P2P transport", "route": TOR},
            {"to": "DNS resolution", "route": LOCAL},
        ]
        if tari_clearnet_sync:
            tari_conns.append({"to": "initial sync (clearnet)", "route": CLEARNET})
        tari_component = {"name": "tari", "firewalled": True, "conns": tari_conns}
    else:
        tari_component = {
            "name": "tari",
            "conns": [{"to": "remote Tari node (gRPC)", "route": tari_route}],
        }

    components = [
        monero_component,
        {
            "name": "p2pool",
            "firewalled": True,
            "conns": [
                {"to": "sidechain P2P peers", "route": CLEARNET if p2pool_clearnet else TOR},
                {"to": "monerod RPC/ZMQ", "route": monero_route},
            ],
        },
        *([tari_component] if tari_enabled else []),
        {
            "name": "xmrig-proxy",
            "firewalled": True,
            "conns": [
                {"to": "upstream pool (local p2pool stratum)", "route": LOCAL},
                # XvB donation mining dials na.xmrvsbeast.com via the proxy's per-pool socks5 (#166).
                {"to": "XvB donation pool", "route": xvb},
                {"to": "dev donation", "route": INACTIVE},  # --donate-level 0 (#166)
            ],
        },
        {
            "name": "dashboard",
            "firewalled": False,  # host-networked — bypasses the #270 DOCKER-USER firewall
            "conns": [
                {"to": "XvB stats (xmrvsbeast.com)", "route": TOR if xvb_enabled else INACTIVE},
                {"to": "update check (github)", "route": TOR},  # socks5h, #224
                {"to": "Healthchecks.io ping", "route": TOR if healthchecks_enabled else INACTIVE},
                {"to": "Telegram bot", "route": TOR if telegram_enabled else INACTIVE},
                {
                    "to": "price feed (coingecko.com)",
                    "route": TOR if price_feed_enabled else INACTIVE,
                },
                {"to": "alert sinks (webhook / ntfy)", "route": sinks},
                {"to": "XvB standby pull (backup ← primary)", "route": standby},
                {"to": "Tor egress probe", "route": TOR if tor_auto_heal else INACTIVE},
                *(
                    [{"to": "remote Tari node (sync gRPC)", "route": tari_route}]
                    if tari_enabled and tari_route != LOCAL
                    else []
                ),
            ],
        },
        {
            "name": "caddy",
            "firewalled": True,
            "conns": [{"to": "TLS (internal CA, no ACME)", "route": LOCAL}],
        },
    ]

    leaks = 0  # clearnet egress that actually exposes the host IP
    blocked = 0  # clearnet route a container is configured for, but the firewall DROPs it
    unverified = 0  # direct hostname route whose exposure cannot be classified without DNS
    for comp in components:
        for conn in comp["conns"]:
            if conn["route"] == UNKNOWN:
                unverified += 1
                continue
            if conn["route"] != CLEARNET:
                continue
            if comp.get("firewalled", False) and firewall:
                conn["blocked_by_firewall"] = True
                blocked += 1
            else:
                leaks += 1

    if leaks:
        label = f"{leaks} clearnet egress path(s) exposing your IP"
        if unverified:
            label += f"; {unverified} path(s) unverified"
    elif unverified:
        label = f"{unverified} egress path(s) unverified; Tor-only status cannot be confirmed"
    elif blocked:
        label = f"All egress via Tor ({blocked} clearnet path(s) blocked by the egress firewall)"
    else:
        label = "All egress via Tor"

    return {
        "components": components,
        "summary": {
            "firewall": firewall,
            "leaks": leaks,
            "blocked_by_firewall": blocked,
            "unverified": unverified,
            "all_tor": leaks == 0 and unverified == 0,
            "level": "ok" if leaks == 0 and unverified == 0 else "warn",
            "label": label,
        },
    }


def egress_posture_from_config():
    """Build the posture from the live dashboard config (values pithead rendered into the env)."""
    return compute_egress_posture(
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
        **_shared_knobs(),
    )


def _shared_knobs():
    """The knobs both from-config builders read: the #380 alert sinks and the #424 Tor probe."""
    urls = [*config.NOTIFY_WEBHOOK_URLS, config.NTFY_URL]
    return {
        "notify_sinks_enabled": any(u.strip() for u in urls if u),
        "notify_tor": config.NOTIFY_TOR,
        "notify_sinks_private": _sinks_all_private(urls),
        "tor_auto_heal": config.TOR_AUTO_HEAL,
    }


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
