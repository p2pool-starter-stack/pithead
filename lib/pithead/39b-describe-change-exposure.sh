# Exposure change descriptions (#2367): keys whose change decides what this host reveals and to
# whom. The ENABLE-exposure direction says what becomes visible, to whom, and what stops being
# blocked, following 39's MONERO_CLEARNET_SYNC pattern; the return direction names what it restores.
describe_exposure_change() { # <key> <old> <new>; sets caller's flag/msg
    local key="$1" new="$3"
    case "$key" in
    TOR_EGRESS_FIREWALL)
        if [ "$new" == "false" ]; then
            flag=CONFIRM
            msg="⚠ Tor-only egress firewall DISABLED — the host rules that drop direct clearnet dials from monerod, p2pool, tari and xmrig-proxy are removed, so a misconfigured or buggy daemon can reach the internet directly and show this host's IP to whatever it dials; each daemon's own Tor setting becomes the only guard, and clearnet initial sync can take effect."
        else
            msg="Tor-only egress firewall ENABLED — direct clearnet dials from the mining containers are dropped again; only the Tor container reaches the internet."
        fi
        ;;
    XVB_TOR_ENABLED)
        if [ "$new" == "false" ]; then
            flag=CONFIRM
            msg="⚠ XvB donation mining OFF Tor — xmrig-proxy dials the XvB pool directly, so XvB sees this host's IP alongside the hashrate it donates; nothing routes that connection through Tor any more."
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
        if [ "$new" == "true" ]; then
            flag=CONFIRM
            msg="⚠ P2Pool sidechain peers over CLEARNET — p2pool dials peers directly and resumes clearnet seed-node DNS lookups, so this host's IP becomes visible to the P2Pool network; its dials no longer go through the Tor proxy."
        else
            msg="P2Pool sidechain peers back on Tor — outbound dials go through the bundled Tor proxy and clearnet seed-node DNS stays off."
        fi
        ;;
    *) return 1 ;;
    esac
}
