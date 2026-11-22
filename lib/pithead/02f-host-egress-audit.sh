HOST_EGRESS_AUDIT_NFT_TABLE="pithead_egress_audit"
HOST_EGRESS_AUDIT_LOG_PREFIX="pithead-egress-audit: "
HOST_EGRESS_AUDIT_LAN_SET="127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10"

host_egress_audit_role() {
    case "${PITHEAD_EGRESS_ROLE:-}" in
    rig)
        printf '%s\n' rig
        return 0
        ;;
    esac
    printf '%s\n' appliance
}

render_host_egress_audit_nft() {
    local role="${1:-}" map="${2:-data/egress-map.tsv}" nets="${3:-$HOST_EGRESS_AUDIT_LAN_SET}"
    case "$role" in appliance | rig) ;; *) return 1 ;; esac
    [ -r "$map" ] || return 1
    awk -v role="$role" -v nets="$nets" -v table="$HOST_EGRESS_AUDIT_NFT_TABLE" -v prefix="$HOST_EGRESS_AUDIT_LOG_PREFIX" '
        BEGIN { FS = "\t"; lan = 0 }
        NR == 1 { next }
        NF < 7 { next }
        $1 == role && $5 == "lan" { lan = 1 }
        END {
            set = ""
            n = split(nets, parts, " ")
            for (i = 1; i <= n; i++) { if (parts[i] == "") continue; set = (set == "" ? parts[i] : set ", " parts[i]) }
            gate = "oifname != \"lo\" ct state != { established, related }"
            v6 = "meta nfproto ipv6 oifname != \"lo\" ct state != { established, related }"
            if (lan && set != "") gate = gate " ip daddr != { " set " }"
            print "add table inet " table
            print "delete table inet " table
            print "table inet " table " {"
            print "  chain output {"
            print "    type filter hook output priority -150; policy accept;"
            print "    oifname \"lo\" counter comment \"loopback\""
            print "    ct state established,related counter comment \"reply\""
            if (lan && set != "") print "    ip daddr { " set " } counter comment \"lan\""
            print "    " gate " counter comment \"would_drop\""
            if (lan && set != "") print "    " v6 " counter comment \"would_drop\""
            print "    " gate " limit rate 30/second log prefix \"" prefix "\""
            if (lan && set != "") print "    " v6 " limit rate 30/second log prefix \"" prefix "\""
            print "  }"
            print "}"
        }
    ' "$map"
}

apply_host_egress_audit() {
    [ "$OS_TYPE" = "Linux" ] || return 0
    command -v nft >/dev/null 2>&1 || return 0
    local map="${1:-data/egress-map.tsv}" role out state
    role=$(host_egress_audit_role)
    out=$(render_host_egress_audit_nft "$role" "$map") || {
        warn "egress-audit:render-failed — could not render the log-only host egress audit table from $map; the audit view is not loaded."
        return 1
    }
    [ -n "$out" ] || return 0
    state="${PITHEAD_EGRESS_AUDIT_STATE:-/run/pithead/egress-audit.rules}"
    if sudo -n nft list table inet "$HOST_EGRESS_AUDIT_NFT_TABLE" >/dev/null 2>&1 &&
        [ -f "$state" ] && printf '%s\n' "$out" | cmp -s - "$state"; then
        log "Host egress audit table already loaded (inet $HOST_EGRESS_AUDIT_NFT_TABLE) — the ruleset is unchanged, so the counters keep accumulating."
        return 0
    fi
    if printf '%s\n' "$out" | sudo nft -f -; then
        sudo mkdir -p "${state%/*}" 2>/dev/null || true
        printf '%s\n' "$out" | sudo tee "$state" >/dev/null 2>&1 || true
        log "Log-only host egress audit table loaded (inet $HOST_EGRESS_AUDIT_NFT_TABLE) — outbound flows are counted and logged, none dropped."
    else
        warn "egress-audit:load-failed — could not load the log-only host egress audit table; nothing is dropped, but host flows are not counted or logged."
        return 1
    fi
}

remove_host_egress_audit() {
    [ "$OS_TYPE" = "Linux" ] || return 0
    command -v nft >/dev/null 2>&1 || return 0
    sudo rm -f "${PITHEAD_EGRESS_AUDIT_STATE:-/run/pithead/egress-audit.rules}" >/dev/null 2>&1 || true
    sudo -n nft delete table inet "$HOST_EGRESS_AUDIT_NFT_TABLE" 2>/dev/null || true
}

host_egress_audit_counters() {
    local out
    command -v nft >/dev/null 2>&1 || return 2
    command -v jq >/dev/null 2>&1 || return 3
    sudo -n nft list tables >/dev/null 2>&1 || return 3
    out=$(sudo -n nft -j list table inet "$HOST_EGRESS_AUDIT_NFT_TABLE" 2>/dev/null) || return 1
    jq -c 'def counters: [.nftables[]? | select(has("rule")) | (.rule.expr[]? | select(has("counter")) | .counter | {packets, bytes})];
        def wd: [.nftables[]? | select(has("rule")) | .rule | select(.comment == "would_drop")
            | .expr[]? | select(has("counter")) | .counter.packets] | add // 0;
        {counters: counters, would_drop: wd}' <<<"$out"
}
