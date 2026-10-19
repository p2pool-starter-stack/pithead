"""Derive outbound routes and privacy state (#170). Selected node sync, P2Pool, and XvB routes
may bypass the host firewall; other container clearnet paths remain blocked. Host traffic is outside it.
"""

import ipaddress
from urllib.parse import urlsplit

from mining_dashboard.config import config
from mining_dashboard.service.health import tari_health
from mining_dashboard.service.network.clearnet_sync import tor_attested
from mining_dashboard.service.network.egress_status import with_firewall_state
from mining_dashboard.service.network.topology_graph import (
    CLEARNET,
    INACTIVE,
    LOCAL,
    TOR,
    UNKNOWN,
    _notify_route,
    _xvb_route,
    node_route,
)


def _xvb_standby_route(source):
    """Route #249 pulls: private IP literals stay local; other hosts use Tor.
    Hostnames cannot be proven private without DNS. The puller's proxy uses this route too."""
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
    tari_explorer=False,
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
                {
                    "to": "Tari explorer reference",
                    "route": TOR if tari_explorer and tari_enabled else INACTIVE,
                },
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

    leaks = 0  # clearnet egress that exposes the host IP without an explicit choice
    chosen = 0
    blocked = 0
    unverified = 0
    for comp in components:
        for conn in comp["conns"]:
            if conn["route"] == UNKNOWN:
                unverified += 1
                continue
            if conn["route"] != CLEARNET:
                continue
            if (
                (comp["name"] in ("monerod", "tari") and "initial" in conn["to"])
                or (comp["name"] == "p2pool" and conn["to"] == "sidechain P2P peers")
                or (comp["name"] == "xmrig-proxy" and conn["to"] == "XvB donation pool")
            ):
                conn["chosen_clearnet"] = True
                chosen += 1
            elif comp.get("firewalled", False) and firewall:
                conn["blocked_by_firewall"] = True
                blocked += 1
            else:
                leaks += 1

    if leaks:
        label = f"{leaks} clearnet egress path(s) exposing your IP"
        if unverified:
            label += f"; {unverified} path(s) unverified"
    elif chosen:
        chains = "Monero" if monero_clearnet_sync else ""
        if tari_clearnet_sync:
            chains += " + Tari" if chains else "Tari"
        label = (
            f"{chains} clearnet first sync or Tor transition pending by your choice — your IP may be visible to peers until host verification"
            if chains
            else ""
        )
        if p2pool_clearnet:
            label += (
                "; " if label else ""
            ) + "P2Pool clearnet by your choice: your IP is visible to peers"
        if xvb_enabled and not xvb_tor:
            label += (
                "; " if label else ""
            ) + "XvB clearnet by your choice: your IP is visible to the pool"
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
            "all_tor": leaks == 0 and chosen == 0 and unverified == 0,
            "level": "ok" if leaks == 0 and chosen == 0 and unverified == 0 else "warn",
            "label": label,
        },
    }


def _sync_pending(chain, flag):
    return flag and not tor_attested(config.CLEARNET_STATE_DIR, chain)


def egress_posture_from_config():
    """Build the posture from the live dashboard config (values pithead rendered into the env)."""
    return with_firewall_state(
        compute_egress_posture,
        firewall=config.TOR_EGRESS_FIREWALL,
        p2pool_clearnet=config.P2POOL_CLEARNET,
        xvb_enabled=config.ENABLE_XVB,
        xvb_tor=config.XVB_TOR_ENABLED,
        monero_clearnet_sync=_sync_pending("monero", config.MONERO_CLEARNET_SYNC),
        tari_clearnet_sync=_sync_pending("tari", config.TARI_CLEARNET_SYNC),
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
    """The knobs both from-config builders read: #380 alert sinks, #424 Tor probe, #2464 explorer."""
    urls = [*config.NOTIFY_WEBHOOK_URLS, config.NTFY_URL]
    return {
        "notify_sinks_enabled": any(u.strip() for u in urls if u),
        "notify_tor": config.NOTIFY_TOR,
        "notify_sinks_private": _sinks_all_private(urls),
        "tor_auto_heal": config.TOR_AUTO_HEAL,
        "tari_explorer": bool(tari_health.TARI_EXPLORER_URL),  # the monitor's own value (#2464)
    }
