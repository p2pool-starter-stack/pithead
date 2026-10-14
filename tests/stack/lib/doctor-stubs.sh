# shellcheck shell=bash
# Shared doctor/chain stubs: each caller builds them in its own process-local sandbox.
build_doctor_stubs() {
    DRBIN="$SANDBOX/drbin"
    mkdir -p "$DRBIN" && cp "$ROOT/tests/stack/fixtures/tor-egress/nft-list-table-2672.json" "$DRBIN/nft-readback.json"
    cat >"$DRBIN/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1" = exec ] && { printf '%s' "${PEERS_JSON:-}"; exit "${PEERS_RC:-0}"; } # #2921 helper: PEERS_JSON, PEERS_RC
name=$(printf '%s' "$*" | sed -n 's/.*name=\^\([a-z0-9-]*\)\$.*/\1/p')
case " ${RUNNING_CONTAINERS:-} " in *" $name "*) echo cid123 ;; esac
exit 0
EOF
    cat >"$DRBIN/sudo" <<'EOF'
#!/usr/bin/env bash
[ "${SUDO_DENY:-0}" = "1" ] && exit 1
[ "$1" = "-n" ] && shift
exec "$@"
EOF
    cat >"$DRBIN/iptables" <<'EOF'
#!/usr/bin/env bash
# `-S FORWARD` answers the jump Docker adds with its first network. This stub ignored its arguments,
# so once the check asserted REACHABILITY (#2091) it read a healthy host as an orphaned chain.
[ "$*" = "-S FORWARD" ] && exec echo '-A FORWARD -j DOCKER-USER'
[ "${IPT_TAGGED:-0}" = "1" ] || exec echo '-P DOCKER-USER ACCEPT'
echo '-A DOCKER-USER -m comment --comment "pithead-tor-egress" -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT'
echo '-A DOCKER-USER -m comment --comment "pithead-tor-egress" -s 172.28.0.0/24 -j DROP'
EOF
    cat >"$DRBIN/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${SS_OUT:-}"
EOF
    cat >"$DRBIN/curl" <<'EOF'
#!/usr/bin/env bash
[ -n "${CURL_BODY:-}" ] && printf '%s' "$CURL_BODY"
exit "${CURL_RC:-0}"
EOF
    # nft for the podman/netavark doctor path: `list tables` always answers (the sudo-readable probe);
    # `list table inet pithead_egress` emits a forward-hooked, dropping ruleset only when NFT_HOOK=1,
    # else exits 1 (table absent). Lets a test distinguish "installed & traversed" from "missing".
    cat >"$DRBIN/nft" <<'EOF'
#!/usr/bin/env bash
# Speaks JSON: the check reads `nft -j` to ask if the drop is a rule IN the forward-hooked chain.
case "$*" in
*"list tables") echo "table inet netavark" ;;
*"list table inet pithead_egress")
    [ "${NFT_HOOK:-0}" = "1" ] || exit 1
    cat "${0%/*}/nft-readback.json" ;;
esac
exit 0
EOF
    chmod +x "$DRBIN"/*
}
