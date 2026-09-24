# --- Tor-only egress: install and remove (#270) ------------------------------------------------
# The apply and remove halves of the firewall in 02-tor-egress.sh, which owns the rule renderers and
# the live enforcement readback these call.
# Remove every rule we previously installed — idempotent, config-agnostic, engine-agnostic. Clears
# BOTH backends so `down` or the opt-out can't leave a stale set behind. An enabled apply never calls
# this: it replaces the rules in one transaction (#2672).
remove_tor_egress_firewall() {
    if command -v nft >/dev/null 2>&1; then
        sudo nft delete table inet "$TOR_EGRESS_NFT_TABLE" 2>/dev/null || true
    fi
    remove_tor_egress_iptables
}

# Delete the tagged DOCKER-USER rules, sparing every foreign one. Best-effort + idempotent.
remove_tor_egress_iptables() {
    command -v iptables >/dev/null 2>&1 || return 0
    local saved match line
    saved=$(sudo iptables-save 2>/dev/null) || return 0
    # Our tagged DOCKER-USER rules (empty if none). `|| true` so a no-match grep (rc 1, under
    # `set -e`/pipefail) doesn't abort — removal is best-effort + idempotent.
    match=$(printf '%s\n' "$saved" | grep -- '^-A DOCKER-USER' | grep -F -- "$TOR_EGRESS_TAG") || true
    [ -n "$match" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # shellcheck disable=SC2086  # intentional word-splitting of the saved rule spec
        sudo iptables -D DOCKER-USER ${line#-A DOCKER-USER } 2>/dev/null || true
    done <<<"$match"
    return 0
}

# One `iptables-restore --noflush` transaction that swaps our tagged DOCKER-USER rules for a fresh
# set: a `-D` for every tagged rule in <iptables-save output> on stdin, then the inserts at 1..n.
# Pure (args + stdin) so it unit-tests. The kernel commits it whole or not at all, so a re-apply
# never leaves the subnet unfenced and a failed load keeps the rules already there (#2672); the
# old remove-then-insert had a window between the two. No `:DOCKER-USER` line: under --noflush both
# backends flush a declared user chain, which would take the foreign rules with it.
render_tor_egress_restore() { # <subnet> <tor_ip>  (stdin: iptables-save)
    local pos=1 line rule
    printf '%s\n' '*filter'
    while IFS= read -r line; do
        case "$line" in "-A DOCKER-USER "*"--comment $TOR_EGRESS_TAG "* | "-A DOCKER-USER "*"--comment \"$TOR_EGRESS_TAG\" "*)
            printf '%s\n' "-D ${line#-A }" ;;
        esac
    done
    while IFS= read -r rule; do
        printf '%s\n' "-I DOCKER-USER $pos -m comment --comment $TOR_EGRESS_TAG $rule"
        pos=$((pos + 1))
    done < <(tor_egress_rules "$1" "$2")
    printf '%s\n' 'COMMIT'
}

# Install (or re-install, idempotently) the fail-closed Tor-only egress rules. Reads the toggle +
# subnet from .env so it works in the `up` path (where config.json isn't re-parsed). Branches to the
# engine's forward-hook mechanism: nftables under podman/netavark, DOCKER-USER under Docker. Each
# backend REPLACES its rules atomically; the other backend's rules are cleared only after the new
# set is in, so an engine change never leaves a moment with neither.
apply_tor_egress_firewall() {
    local enabled subnet tor_ip
    enabled=$(env_get TOR_EGRESS_FIREWALL 2>/dev/null)
    [ -n "$enabled" ] || enabled=true
    if [ "$(normalize_bool "$enabled")" != "true" ]; then
        remove_tor_egress_firewall
        warn "Tor-only egress firewall is OFF (network.tor_egress_firewall=false) — a misconfigured app could reach clearnet."
        remove_tor_egress_boot_unit
        return 0
    fi
    subnet=$(env_get NETWORK_SUBNET 2>/dev/null)
    [ -n "$subnet" ] || subnet="172.28.0.0/24"
    tor_ip=$(env_get NETWORK_PREFIX 2>/dev/null)
    [ -n "$tor_ip" ] || tor_ip="172.28.0"
    tor_ip="${tor_ip}.25"
    if [ "$(container_engine)" = "podman" ]; then
        apply_tor_egress_nft "$subnet" "$tor_ip" && remove_tor_egress_iptables
    else
        if apply_tor_egress_iptables "$subnet" "$tor_ip" && command -v nft >/dev/null 2>&1; then
            sudo nft delete table inet "$TOR_EGRESS_NFT_TABLE" 2>/dev/null || true
        fi
        provision_tor_egress_boot_unit "$subnet" "$tor_ip"
    fi
    return 0
}

# Appliance/netavark path: load the independent nft table (atomic, idempotent-replace), then PROVE
# it landed before saying so.
apply_tor_egress_nft() { # <subnet> <tor_ip>
    local subnet="$1" tor_ip="$2" br rc=0
    if ! command -v nft >/dev/null 2>&1; then
        warn "egress-apply:nft-missing — nftables not found, cannot enforce Tor-only egress. The stack runs, but clearnet egress is NOT fail-closed."
        return 1
    fi
    # mining_net is IPv4-only by design, so br is empty and the ruleset stays v4-only. If it ever
    # gains an IPv6 subnet we key a v6 fail-closed drop on its bridge interface. rc 3 means v6 is
    # present but the bridge couldn't be resolved — refuse rather than load a v4-only firewall we'd
    # then wrongly report as fail-closed (a v6 clearnet leak would fall through policy accept).
    #
    # `|| rc=$?`, not a bare assignment followed by `rc=$?` (#2059): the program runs under
    # `set -Eeuo pipefail`, where `br=$(f)` with a non-zero f is a failing simple command — errexit
    # fires and the shell is GONE before the next line can read $?. The refusal below was therefore
    # unreachable, and a v6-capable mining_net killed `up` mid-stack_up with rc 3 and no message at
    # all. Guarding the assignment is what makes the branch it guards able to run.
    br=$(mining_net_ipv6_bridge) || rc=$?
    if [ "$rc" -eq 3 ]; then
        warn "egress-apply:v6-bridge-unresolved — mining_net has an IPv6 subnet but its bridge interface could not be resolved. REFUSING to install a v4-only egress firewall that would leave IPv6 clearnet un-fenced. Recreate mining_net or set network.tor_egress_firewall=false to acknowledge."
        return 1
    fi
    # One transaction: a failed load leaves the table already there, whole (#2672).
    if ! render_tor_egress_nft "$subnet" "$tor_ip" "$br" | sudo nft -f - 2>/dev/null; then
        warn "egress-apply:nft-load-failed — could not load the Tor-egress firewall (needs root + nftables); any rules already installed are unchanged. Clearnet egress is NOT provably fail-closed."
        return 1
    fi
    tor_egress_verify_or_warn "Tor-only egress enforced: clearnet dials from $subnet${br:+ (IPv4) and via $br (IPv6)} dropped except via Tor ($tor_ip)."
}

# DIY/Docker path: swap the tagged rules in DOCKER-USER, which Docker jumps to from FORWARD, in one
# iptables-restore transaction (render_tor_egress_restore).
apply_tor_egress_iptables() { # <subnet> <tor_ip>
    local subnet="$1" tor_ip="$2" saved
    if ! command -v iptables >/dev/null 2>&1 || ! command -v iptables-restore >/dev/null 2>&1; then
        warn "egress-apply:iptables-missing — iptables/iptables-restore not found, cannot enforce Tor-only egress. The stack runs, but clearnet egress is NOT fail-closed."
        return 1
    fi
    # DOCKER-USER may not exist yet on a first-ever `up` (Docker creates it with its first network).
    # Pre-create it so installing here — before compose runs — succeeds; Docker adopts the existing
    # chain and adds the FORWARD jump. Harmless (-N fails with rc 1) once the chain is already there.
    sudo iptables -N DOCKER-USER 2>/dev/null || true
    if ! saved=$(sudo iptables-save -t filter 2>/dev/null) ||
        ! render_tor_egress_restore "$subnet" "$tor_ip" <<<"$saved" | sudo iptables-restore -w --noflush 2>/dev/null; then
        warn "egress-apply:iptables-insert-failed — could not load the Tor-egress firewall (needs root + iptables); any rules already installed are unchanged. Clearnet egress is NOT provably fail-closed."
        return 1
    fi
    tor_egress_verify_or_warn "Tor-only egress enforced: clearnet dials from $subnet dropped except via Tor ($tor_ip)."
}
