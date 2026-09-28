# Exposure change descriptions (#2367): keys whose change decides what this host reveals and to
# whom. The ENABLE-exposure direction says what becomes visible, to whom, and what stops being
# blocked, following 39's MONERO_CLEARNET_SYNC pattern; the return direction names what it restores.
# Whether <component>'s direct dials actually leave this host under the candidate config (the
# preview parses it first, so TOR_EGRESS_FIREWALL is the value being committed): yes with the
# Tor-only egress firewall off, or on with a scoped exemption for that component. Choosing a
# clearnet route is the operator's call either way; this only decides what the preview can say is
# exposed.
egress_direct_for() { # <p2pool|xmrig-proxy>
    [ "${TOR_EGRESS_FIREWALL:-true}" = false ] && return 0
    egress_firewall_exempts "$1"
}

# ponytail: no per-component exemption exists yet, so the firewall blocks every chosen clearnet
# route; the scoped exemption (#2790) replaces this with the real check.
egress_firewall_exempts() { return 1; } # <component>

describe_exposure_change() { # <key> <old> <new>; sets caller's flag/msg
    local key="$1" new="$3"
    case "$key" in
    TOR_EGRESS_FIREWALL)
        if [ "$new" == "false" ]; then
            flag=CONFIRM
            msg="⚠ Tor-only egress firewall DISABLED — the host rules that drop direct clearnet dials from monerod, p2pool, tari and xmrig-proxy are removed, so a misconfigured or buggy daemon can reach the internet directly and show this host's IP to whatever it dials; each daemon's own Tor setting becomes the only guard."
        else
            msg="Tor-only egress firewall ENABLED — direct clearnet dials from the mining containers are dropped again; only the Tor container reaches the internet."
        fi
        ;;
    XVB_TOR_ENABLED)
        if [ "$new" == "false" ] && egress_direct_for xmrig-proxy; then
            flag=CONFIRM
            msg="⚠ XvB donation mining OFF Tor — xmrig-proxy dials the XvB pool directly and that route is open, so XvB sees this host's IP alongside the hashrate it donates."
        elif [ "$new" == "false" ]; then
            flag=CONFIRM
            msg="XvB donation mining set OFF Tor — xmrig-proxy stops routing the XvB pool through Tor, but the Tor-only egress firewall blocks its direct dial, so this host's IP is not exposed and the XvB connection fails while that route stays blocked."
        else
            msg="XvB donation mining back on Tor — the XvB pool sees a Tor exit, not this host's IP."
        fi
        ;;
    DASHBOARD_EXPOSE_PUBLIC_IP)
        if [ "$new" == "true" ]; then
            flag=CONFIRM
            msg="⚠ Dashboard PUBLISHED on this machine's globally-routable addresses — on a network that passes IPv6 through, anyone on the internet can reach the dashboard login; those addresses are no longer kept out of the site list and listener, so only the login and your own protection guard it."
        else
            msg="Dashboard back to LAN, ULA and loopback addresses only — globally-routable addresses leave its site list and listener."
        fi
        ;;
    P2POOL_CLEARNET)
        if [ "$new" == "true" ] && egress_direct_for p2pool; then
            flag=CONFIRM
            msg="⚠ P2Pool sidechain peers over CLEARNET — p2pool dials peers directly and resumes clearnet seed-node DNS lookups, and that route is open, so this host's IP becomes visible to the P2Pool network."
        elif [ "$new" == "true" ]; then
            flag=CONFIRM
            msg="P2Pool sidechain peers set to CLEARNET — p2pool stops using the Tor proxy, but the Tor-only egress firewall blocks its direct dials, so this host's IP is not exposed and P2Pool gets no clearnet sidechain peers while that route stays blocked."
        else
            msg="P2Pool sidechain peers back on Tor — outbound dials go through the bundled Tor proxy and clearnet seed-node DNS stays off."
        fi
        ;;
    *) return 1 ;;
    esac
}
