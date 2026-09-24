# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Tor-egress and flows that are already open (#2672). The conntrack accept used to pass every
# ESTABLISHED packet whoever opened the flow, so a direct clearnet dial made while the rules were
# absent (a re-apply's remove-then-insert, a rolled-back insert) stayed open under the firewall.
# These pin the two halves of the fix in both backends, and that the enforcement readback still
# calls the new ruleset enforced: the tagged reset sits above the DROP, where the shadow walk looks.
#
# The readbacks under tests/stack/fixtures/tor-egress/ are real kernel output, not hand-written:
# `iptables -S DOCKER-USER` (iptables 1.8.10) and `nft -j list table inet pithead_egress`
# (nftables 1.0.9), each taken in a scratch network namespace right after installing this ruleset
# for 172.28.0.0/24. Self-contained stubs, so run.sh's source order cannot matter.
# Sourced by tests/stack/run.sh.

EGD="$SANDBOX/egress-direction"
EGD_FIX="$ROOT/tests/stack/fixtures/tor-egress"
mkdir -p "$EGD/bin"

echo "== unit: tor_egress_rules / render_tor_egress_nft — replies only, a grandfathered flow is reset (#2672) =="
EGD_IPT=$(run_sourced "$SANDBOX" tor_egress_rules 172.28.0.0/24 172.28.0.25)
assert_not_contains "iptables: no conntrack ACCEPT blind to direction" "$EGD_IPT" "ESTABLISHED,RELATED -j ACCEPT"
assert_eq "iptables: an established TCP packet the app sends to a public address is reset, just above the DROP" \
    "$(printf '%s\n' "$EGD_IPT" | tail -2)" \
    "$(printf '%s\n' "-s 172.28.0.0/24 -p tcp -m conntrack --ctstate ESTABLISHED -j REJECT --reject-with tcp-reset" "-s 172.28.0.0/24 -j DROP")"
EGD_NFT=$(run_sourced "$SANDBOX" render_tor_egress_nft 172.28.0.0/24 172.28.0.25 | grep -E ' (accept|drop|reject)')
assert_eq "nft: the only ct accept is the reply-direction one" \
    "$(printf '%s\n' "$EGD_NFT" | grep 'ct state' | grep accept)" "    ct direction reply ct state established,related accept"
assert_eq "nft: an established TCP packet the app sends to a public address is reset, just above the drop" \
    "$(printf '%s\n' "$EGD_NFT" | tail -2)" \
    "$(printf '%s\n' "    ip saddr 172.28.0.0/24 meta l4proto tcp ct state established reject with tcp reset" "    ip saddr 172.28.0.0/24 drop")"
assert_eq "nft: v6 backstop still closes the chain after the reset" \
    "$(run_sourced "$SANDBOX" render_tor_egress_nft 172.28.0.0/24 172.28.0.25 podman1 | grep -E ' (accept|drop|reject)' | tail -1)" \
    "    iifname \"podman1\" meta nfproto ipv6 drop"

echo "== enforcement: the kernel's readback of the new ruleset is still 'enforced' (#2672) =="
assert_eq "harness: the iptables fixture carries the tagged reset above the tagged DROP" \
    "$(grep -c -- '--comment pithead-tor-egress' "$EGD_FIX/iptables-S-docker-user-2672.txt")" "8"
cat >"$EGD/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -n | -H | -E) shift ;; *) break ;; esac; done
exec "$@"
SUDO
cat >"$EGD/bin/iptables" <<IPT
#!/usr/bin/env bash
case "\$*" in
"-S DOCKER-USER") cat "$EGD_FIX/iptables-S-docker-user-2672.txt" ;;
"-S FORWARD") echo '-A FORWARD -j DOCKER-USER' ;;
"-S") echo '-P FORWARD ACCEPT' ;;
esac
exit 0
IPT
cat >"$EGD/bin/nft" <<NFT
#!/usr/bin/env bash
case "\$*" in
"list tables") echo "table inet pithead_egress" ;;
*"list table inet pithead_egress") cat "$EGD_FIX/nft-list-table-2672.json" ;;
esac
exit 0
NFT
chmod +x "$EGD"/bin/*
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$EGD/.env"
egd_rc() { # <engine> -> rc of the real tor_egress_enforced
    local rc=0
    PITHEAD_ENGINE="$1" PATH="$EGD/bin:$PATH" run_sourced "$EGD" tor_egress_enforced >/dev/null 2>&1 || rc=$?
    echo "$rc"
}
assert_eq "iptables: our own reset above our DROP is not read as a foreign shadow" "$(egd_rc docker)" "0"
assert_eq "nft: the reset rule ahead of the drop leaves the hooked chain enforced" "$(egd_rc podman)" "0"

echo "== unit: render_tor_egress_restore — a re-apply is one transaction, never remove-then-insert (#2672) =="
EGD_SAVED=$(printf '%s\n' '*filter' ':DOCKER-USER - [0:0]' \
    '-A DOCKER-USER -s 10.9.0.0/16 -j ACCEPT' '-A DOCKER-USER -m comment --comment "not pithead-tor-egress" -j ACCEPT' \
    '-A DOCKER-USER -s 172.28.0.25/32 -m comment --comment pithead-tor-egress -j ACCEPT' \
    '-A DOCKER-USER -s 172.28.0.0/24 -m comment --comment pithead-tor-egress -j DROP' \
    '-A DOCKER-USER -j RETURN' 'COMMIT')
EGD_TXN=$(run_sourced "$SANDBOX" render_tor_egress_restore 172.28.0.0/24 172.28.0.25 <<<"$EGD_SAVED")
assert_eq "opens the filter table and commits once" "$(printf '%s\n' "$EGD_TXN" | sed -n '1p;$p' | tr '\n' ' ')" "*filter COMMIT "
assert_eq "deletes exactly the tagged rules already installed, inside the transaction" \
    "$(printf '%s\n' "$EGD_TXN" | grep -- '^-D ')" \
    "$(printf '%s\n' '-D DOCKER-USER -s 172.28.0.25/32 -m comment --comment pithead-tor-egress -j ACCEPT' '-D DOCKER-USER -s 172.28.0.0/24 -m comment --comment pithead-tor-egress -j DROP')"
assert_eq "inserts the full rule set at 1..n, DROP last" \
    "$(printf '%s\n' "$EGD_TXN" | grep -- '^-I ' | sed 's/^-I DOCKER-USER [0-9]* -m comment --comment pithead-tor-egress //')" "$EGD_IPT"
assert_eq "numbers the inserts 1..8" "$(printf '%s\n' "$EGD_TXN" | grep -- '^-I ' | awk '{print $3}' | tr '\n' ' ')" "1 2 3 4 5 6 7 8 "
assert_not_contains "never declares DOCKER-USER: legacy --noflush would flush the foreign rules" "$EGD_TXN" ":DOCKER-USER"

echo "== black-box: an engine's own load failure leaves the other backend's rules alone (#2672) =="
cat >"$EGD/bin/nft" <<'NFT'
#!/usr/bin/env bash
printf 'nft %s\n' "$*" >>"$EGD_LOG"
case "$*" in -f*) cat >/dev/null; exit "${NFT_LOAD_RC:-0}" ;; esac
exit 0
NFT
printf '#!/usr/bin/env bash\nprintf "ipt %%s\\n" "$*" >>"$EGD_LOG"\n' >"$EGD/bin/iptables"
printf '#!/usr/bin/env bash\necho "-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP"\n' >"$EGD/bin/iptables-save"
chmod +x "$EGD"/bin/*
egd_apply() { # <NFT_LOAD_RC> -> the stub log of a podman apply
    : >"$EGD/log"
    EGD_LOG="$EGD/log" NFT_LOAD_RC="$1" PITHEAD_ENGINE=podman PATH="$EGD/bin:$PATH" \
        run_sourced "$EGD" apply_tor_egress_firewall >/dev/null 2>&1
    cat "$EGD/log"
}
EGD_OUT=$(egd_apply 1)
assert_not_contains "nft load refused: the old table is never deleted outside the transaction" "$EGD_OUT" "delete table"
assert_not_contains "nft load refused: the iptables rules are left in place" "$EGD_OUT" "ipt -D"
EGD_OUT=$(egd_apply 0)
assert_contains "nft loaded: the stale iptables set from an engine change is cleared afterwards" "$EGD_OUT" "ipt -D DOCKER-USER"
assert_eq "nft loaded: the load comes before that clear-up" \
    "$(printf '%s\n' "$EGD_OUT" | grep -nE '^(nft -f|ipt -D)' | cut -d: -f2 | cut -c1-6 | tr '\n' ' ')" "nft -f ipt -D "
