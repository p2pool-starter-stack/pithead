# --- Tor-only egress: install and remove (#270) ------------------------------------------------
# The apply and remove halves of the firewall in 02-tor-egress.sh, which owns the rule renderers and
# the live enforcement readback these call.
# The entrypoint/status predicate is shared with firewall install and verification. Only the
# fixed node addresses may bypass the IPv4 DROP, and a marker spends that exemption for good.
tor_egress_sync_ips() {
    local prefix
    prefix=$(env_get NETWORK_PREFIX 2>/dev/null)
    [ -n "$prefix" ] || prefix=172.28.0
    [ "$(env_get MONERO_CLEARNET_SYNC 2>/dev/null)" = true ] &&
        [ ! -f "$(clearnet_state_dir)/monero.synced" ] && printf '%s\n' "$prefix.26"
    [ "$(env_get TARI_CLEARNET_SYNC 2>/dev/null)" = true ] &&
        [ ! -f "$(clearnet_state_dir)/tari.synced" ] && printf '%s\n' "$prefix.27"
    return 0
}

tor_egress_sync_rules_match() { # <nft|iptables> <live rules>
    local backend="$1" out="$2" prefix ip actual expected active
    prefix=$(env_get NETWORK_PREFIX 2>/dev/null)
    [ -n "$prefix" ] || prefix=172.28.0
    active=$(tor_egress_sync_ips)
    for ip in "$prefix.26" "$prefix.27"; do
        if [ "$backend" = nft ]; then
            actual=$(jq --arg ip "$ip" '[.nftables[] | select(.rule?.chain == "forward")
                | .rule.expr | select(.[-1] == {"accept":null})
                | .[] | select(.match?.left?.payload? == {"protocol":"ip","field":"saddr"})
                | select(.match.right == $ip)] | length' <<<"$out") || return 1
        else
            actual=$(grep -Ec -- "$TOR_EGRESS_TAG.* -s $ip(/32)? -j ACCEPT$" <<<"$out") || true
        fi
        expected=0
        grep -Fxq -- "$ip" <<<"$active" && expected=1
        [ "$actual" = "$expected" ] || return 1
    done
}

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
render_tor_egress_restore() { # <subnet> <tor_ip> [sync-ip ...] (stdin: iptables-save)
    local pos=1 line rule
    printf '%s\n' '*filter'
    while IFS= read -r line; do
        case "$line" in "-A DOCKER-USER "*"--comment $TOR_EGRESS_TAG "* | "-A DOCKER-USER "*"--comment \"$TOR_EGRESS_TAG\" "*)
            printf '%s\n' "-D ${line#-A }"
            ;;
        esac
    done
    while IFS= read -r rule; do
        printf '%s\n' "-I DOCKER-USER $pos -m comment --comment $TOR_EGRESS_TAG $rule"
        pos=$((pos + 1))
    done < <(tor_egress_rules "$@")
    printf '%s\n' 'COMMIT'
}

# Install (or re-install, idempotently) the fail-closed Tor-only egress rules. Reads the toggle +
# subnet from .env so it works in the `up` path (where config.json isn't re-parsed). Branches to the
# engine's forward-hook mechanism: nftables under podman/netavark, DOCKER-USER under Docker. Each
# backend REPLACES its rules atomically; the other backend's rules are cleared only after the new
# set is in, so an engine change never leaves a moment with neither.
apply_tor_egress_firewall() {
    local enabled subnet tor_ip
    local -a sync_ips=()
    enabled=$(env_get TOR_EGRESS_FIREWALL 2>/dev/null)
    [ -n "$enabled" ] || enabled=true
    if [ "$(normalize_bool "$enabled")" != "true" ]; then
        remove_tor_egress_firewall
        warn "Tor-only egress firewall is OFF (network.tor_egress_firewall=false) — a misconfigured app could reach clearnet."
        remove_tor_egress_boot_unit
        [ "${1:-}" = refresh ] || provision_egress_sync_runner || return 1
        return 0
    fi
    subnet=$(env_get NETWORK_SUBNET 2>/dev/null)
    [ -n "$subnet" ] || subnet="172.28.0.0/24"
    tor_ip=$(env_get NETWORK_PREFIX 2>/dev/null)
    [ -n "$tor_ip" ] || tor_ip="172.28.0"
    tor_ip="${tor_ip}.25"
    mapfile -t sync_ips < <(tor_egress_sync_ips)
    if [ "$(container_engine)" = "podman" ]; then
        apply_tor_egress_nft "$subnet" "$tor_ip" "${sync_ips[@]}" && remove_tor_egress_iptables
    else
        if apply_tor_egress_iptables "$subnet" "$tor_ip" "${sync_ips[@]}" && command -v nft >/dev/null 2>&1; then
            sudo nft delete table inet "$TOR_EGRESS_NFT_TABLE" 2>/dev/null || true
        fi
        [ "${1:-}" = refresh ] || provision_tor_egress_boot_unit "$subnet" "$tor_ip" "${sync_ips[@]}"
    fi
    [ "${1:-}" = refresh ] || provision_egress_sync_runner || return 1
    return 0
}

# A host request can only close an exemption for a chain whose marker exists. The readback is the
# same one apply/doctor use and must agree with BOTH chains' flags and markers (#2059/#2678).
egress_sync_refresh() { # <monero|tari>
    local chain="$1" enabled rc=0 prefix ip out
    case "$chain" in monero | tari) ;; *) return 1 ;; esac
    [ -f "$(clearnet_state_dir)/$chain.synced" ] || return 1
    apply_tor_egress_firewall refresh
    enabled=$(env_get TOR_EGRESS_FIREWALL 2>/dev/null)
    if [ "$(normalize_bool "${enabled:-true}")" = true ]; then
        tor_egress_enforced || rc=$?
        [ "$rc" -eq 0 ]
        return
    fi
    # An explicit firewall opt-out has no chain exemption to remove, but the old tagged rules
    # must actually be gone before the supervisor may call this transition complete.
    prefix=$(env_get NETWORK_PREFIX 2>/dev/null)
    [ -n "$prefix" ] || prefix=172.28.0
    case "$chain" in monero) ip="$prefix.26" ;; tari) ip="$prefix.27" ;; esac
    if [ "$(container_engine)" = podman ]; then
        out=$(sudo -n nft -j list table inet "$TOR_EGRESS_NFT_TABLE" 2>/dev/null) || {
            sudo -n nft list tables >/dev/null 2>&1 || return 1
            return 0
        }
        ! jq -e --arg ip "$ip" '[.nftables[] | select(.rule?.chain == "forward") | .rule.expr[]
            | select(.match?.left?.payload? == {"protocol":"ip","field":"saddr"})
            | select(.match.right == $ip)] | length > 0' <<<"$out" >/dev/null
    else
        out=$(sudo -n iptables -S DOCKER-USER 2>/dev/null) || {
            sudo -n iptables -S >/dev/null 2>&1 || return 1
            return 0
        }
        ! grep -Eq -- "$TOR_EGRESS_TAG.* -s $ip(/32)? -j ACCEPT$" <<<"$out"
    fi
}

# Control-off hosts still need a root-side trigger. It watches only the supervisor's separate
# request directory, so enabling it never opens the operator-facing dashboard control channel.
provision_egress_sync_runner() {
    [ "$OS_TYPE" = Linux ] && command -v systemctl >/dev/null 2>&1 || return 0
    local unit_dir pwd_p state_dir engine enabled service path owner owner_p
    local -a enable_args=(enable --now)
    unit_dir=$(control_unit_dir)
    case "$unit_dir" in /run/*) enable_args=(enable --runtime --now) ;; esac
    service="$unit_dir/pithead-egress-sync.service"
    path="$unit_dir/pithead-egress-sync.path"
    enabled=$(env_get DASHBOARD_CONTROL_ENABLED 2>/dev/null)
    pwd_p=$(pwd -P)
    if [ -e "$service" ] || [ -e "$path" ]; then
        owner=$(sed -n 's|^ExecStart=\(/.*\)/pithead egress-run-pending$|\1|p' "$service" 2>/dev/null | head -1)
        if [ -z "$owner" ]; then
            warn "Existing egress-sync runner is not a Pithead unit; leaving it alone."
            return 1
        fi
        owner_p=$(cd "$owner" 2>/dev/null && pwd -P) || owner_p="$owner"
        if [ -n "$owner" ] && [ "$owner_p" != "$pwd_p" ] && [ -d "$owner_p" ] &&
            [ "${PITHEAD_STEAL_CONTROL_UNITS:-0}" != 1 ]; then
            warn "Existing egress-sync runner belongs to another checkout; leaving it alone."
            return 1
        fi
    fi
    if [ "$enabled" = true ]; then
        if [ -e "$service" ] || [ -e "$path" ]; then
            sudo systemctl disable --now pithead-egress-sync.path >/dev/null 2>&1 || true
            sudo rm -f "$service" "$path"
            sudo systemctl daemon-reload
        fi
        return 0
    fi
    state_dir=$(clearnet_state_dir)
    mkdir -p "$state_dir/requests"
    sudo chmod 777 "$state_dir/requests" 2>/dev/null || chmod 777 "$state_dir/requests" || return 1
    engine=$(container_engine)
    if grep -qsF "ExecStart=$pwd_p/pithead egress-run-pending" "$service" &&
        grep -qsF "PathExistsGlob=$state_dir/requests/*.json" "$path" &&
        grep -qsF "Environment=PITHEAD_ENGINE=$engine" "$service" &&
        systemctl is-enabled pithead-egress-sync.path >/dev/null 2>&1; then
        return 0
    fi
    sudo tee "$service" >/dev/null <<EOF
[Unit]
Description=Close completed Pithead clearnet sync firewall exemptions
StartLimitIntervalSec=0

[Service]
Type=oneshot
User=root
WorkingDirectory=$pwd_p
Environment=PITHEAD_ENGINE=$engine
Restart=on-failure
RestartSec=15
ExecStart=$pwd_p/pithead egress-run-pending
EOF
    sudo tee "$path" >/dev/null <<EOF
[Unit]
Description=Watch completed Pithead clearnet sync requests

[Path]
PathExistsGlob=$state_dir/requests/*.json

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl "${enable_args[@]}" pithead-egress-sync.path >/dev/null 2>&1 || {
        warn "Could not enable pithead-egress-sync.path — clearnet sync transitions cannot finish without a host firewall refresh."
        return 1
    }
}

egress_sync_run_pending() {
    local state_dir cdir file name id chain ok
    state_dir=$(clearnet_state_dir)
    cdir=$(env_get CONTROL_DIR 2>/dev/null)
    [ -n "$cdir" ] || cdir="$PWD/data/control"
    mkdir -p "$cdir/results"
    for file in "$state_dir"/requests/*.json; do
        [ -e "$file" ] || continue
        [ -f "$file" ] && [ ! -L "$file" ] && [ "$(wc -c <"$file")" -le 1024 ] || {
            rm -f "$file"
            continue
        }
        name=${file##*/}
        id=${name%.json}
        [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || {
            rm -f "$file"
            continue
        }
        chain=$(jq -r --arg id "$id" 'if .id == $id and .action == "egress-sync" and
            ((keys | sort) == ["action","chain","id"]) and (.chain == "monero" or .chain == "tari")
            then .chain else empty end' "$file" 2>/dev/null) || chain=""
        ok=false
        [ -n "$chain" ] && egress_sync_refresh "$chain" && ok=true
        if [ "$ok" = true ]; then
            control_write_result "$cdir/results" "$id" "$(jq -n --arg chain "$chain" '{status:"applied",chain:$chain,ts:(now|floor)}')"
        else
            control_write_result "$cdir/results" "$id" "$(jq -n '{status:"failed",error:"firewall refresh or live-rule verification failed",ts:(now|floor)}')"
        fi
        rm -f "$file"
    done
}

control_egress_sync() { # <id> <chain> <control-dir>
    local id="$1" chain="$2" cdir="$3"
    if egress_sync_refresh "$chain"; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg chain "$chain" '{status:"applied",chain:$chain,ts:(now|floor)}')"
    else
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"failed",error:"firewall refresh or live-rule verification failed",ts:(now|floor)}')"
    fi
}

# Appliance/netavark path: load the independent nft table (atomic, idempotent-replace), then PROVE
# it landed before saying so.
apply_tor_egress_nft() { # <subnet> <tor_ip> [sync-ip ...]
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
    shift 2
    if ! render_tor_egress_nft "$subnet" "$tor_ip" "$br" "$@" | sudo nft -f - 2>/dev/null; then
        warn "egress-apply:nft-load-failed — could not load the Tor-egress firewall (needs root + nftables); any rules already installed are unchanged. Clearnet egress is NOT provably fail-closed."
        return 1
    fi
    tor_egress_verify_or_warn "Tor-only egress enforced: clearnet dials from $subnet${br:+ (IPv4) and via $br (IPv6)} dropped except via Tor ($tor_ip)."
}

# DIY/Docker path: swap the tagged rules in DOCKER-USER, which Docker jumps to from FORWARD, in one
# iptables-restore transaction (render_tor_egress_restore).
apply_tor_egress_iptables() { # <subnet> <tor_ip> [sync-ip ...]
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
        ! render_tor_egress_restore "$@" <<<"$saved" | sudo iptables-restore -w --noflush 2>/dev/null; then
        warn "egress-apply:iptables-insert-failed — could not load the Tor-egress firewall (needs root + iptables); any rules already installed are unchanged. Clearnet egress is NOT provably fail-closed."
        return 1
    fi
    tor_egress_verify_or_warn "Tor-only egress enforced: clearnet dials from $subnet dropped except via Tor ($tor_ip)."
}
