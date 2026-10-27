# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
build_val_sandbox
DOCKER_LOG="$V/docker.log"
echo "== unit: tor_egress_rules — fail-closed Tor-only egress ruleset (#270) =="
TER=$(run_sourced "$SANDBOX" tor_egress_rules 172.28.0.0/24 172.28.0.25)
assert_eq "the conntrack ACCEPT comes first and passes REPLIES only (#2672)" "$(printf '%s\n' "$TER" | head -1)" "-m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT"
assert_contains "only Tor (.25) may egress to the internet" "$TER" "-s 172.28.0.25 -j ACCEPT"
assert_contains "inter-container + 172.16/12 LAN allowed" "$TER" "-s 172.28.0.0/24 -d 172.16.0.0/12 -j ACCEPT"
assert_contains "10/8 LAN allowed" "$TER" "-s 172.28.0.0/24 -d 10.0.0.0/8 -j ACCEPT"
assert_contains "192.168/16 LAN allowed" "$TER" "-s 172.28.0.0/24 -d 192.168.0.0/16 -j ACCEPT"
assert_eq "the clearnet DROP is the FINAL rule (fail-closed)" "$(printf '%s\n' "$TER" | tail -1)" "-s 172.28.0.0/24 -j DROP"
assert_contains "honours a custom subnet/prefix (#180)" "$(run_sourced "$SANDBOX" tor_egress_rules 172.30.5.0/24 172.30.5.25)" "-s 172.30.5.0/24 -j DROP"
echo "== unit: render_tor_egress_nft — same allow-set as nftables for the netavark path (#855) =="
NFTR=$(run_sourced "$SANDBOX" render_tor_egress_nft 172.28.0.0/24 172.28.0.25)
assert_contains "hooks the chain at forward so packets actually traverse it" "$NFTR" "hook forward"
assert_contains "priority -5 runs ahead of netavark's priority-0 blanket accept" "$NFTR" "priority -5"
assert_eq "the ct accept comes first and passes REPLIES only (#2672)" "$(printf '%s\n' "$NFTR" | grep -E ' (accept|drop)$' | head -1)" "    ct direction reply ct state established,related accept"
assert_contains "only Tor (.25) may egress to the internet" "$NFTR" "ip saddr 172.28.0.25 accept"
assert_contains "inter-container + 172.16/12 LAN allowed" "$NFTR" "ip saddr 172.28.0.0/24 ip daddr 172.16.0.0/12 accept"
assert_contains "100.64/10 CGNAT LAN allowed" "$NFTR" "ip saddr 172.28.0.0/24 ip daddr 100.64.0.0/10 accept"
assert_eq "the clearnet DROP is the FINAL rule before the chain closes (fail-closed)" "$(printf '%s\n' "$NFTR" | grep -E 'accept|drop' | tail -1)" "    ip saddr 172.28.0.0/24 drop"
assert_contains "idempotent-replace: add table first" "$NFTR" "add table inet pithead_egress"
assert_contains "idempotent-replace: delete before recreating" "$NFTR" "delete table inet pithead_egress"
assert_contains "honours a custom subnet/prefix (#180)" "$(run_sourced "$SANDBOX" render_tor_egress_nft 172.30.5.0/24 172.30.5.25)" "ip saddr 172.30.5.0/24 drop"
echo "== unit: render_tor_egress_nft — IPv6 backstop only when the mining bridge is passed (#858) =="
assert_not_contains "no bridge arg → no IPv6 rule at all (v4-only, the normal case)" "$NFTR" "ip6"
NFTR6=$(run_sourced "$SANDBOX" render_tor_egress_nft 172.28.0.0/24 172.28.0.25 podman1)
assert_contains "v6 drop is scoped to the mining bridge, never the whole forward path" "$NFTR6" 'iifname "podman1" meta nfproto ipv6 drop'
assert_contains "v6 LAN ULA (fc00::/7) allowed off the bridge" "$NFTR6" 'iifname "podman1" ip6 daddr fc00::/7 accept'
assert_contains "v6 link-local (fe80::/10) allowed off the bridge" "$NFTR6" 'iifname "podman1" ip6 daddr fe80::/10 accept'
assert_eq "the IPv6 drop is the FINAL rule before the chain closes (fail-closed)" "$(printf '%s\n' "$NFTR6" | grep -E 'accept|drop' | tail -1)" '    iifname "podman1" meta nfproto ipv6 drop'
assert_contains "the v4 allow-set is unchanged when v6 is added" "$NFTR6" "ip saddr 172.28.0.0/24 drop"
echo "== unit: mining_net_ipv6_bridge — resolve bridge only when mining_net has a v6 subnet (#858) =="
NB="$SANDBOX/netbr"
mkdir -p "$NB/bin"
cat >"$NB/bin/podman" <<'PM'
#!/usr/bin/env bash
[ "$1" = "network" ] && [ "$2" = "inspect" ] || { echo "[]"; exit 0; }
echo '[{"name":"mining_net","network_interface":"podman1","subnets":[{"subnet":"172.28.0.0/24"}]}]'
PM
chmod +x "$NB/bin/podman"
assert_eq "v4-only mining_net → no bridge (stays v4-only), rc 0" "$(
    PATH="$NB/bin:$PATH" run_sourced "$NB" mining_net_ipv6_bridge
    echo " rc=$?"
)" " rc=0"
cat >"$NB/bin/podman" <<'PM'
#!/usr/bin/env bash
echo '[{"name":"mining_net","network_interface":"podman4","subnets":[{"subnet":"172.28.0.0/24"},{"subnet":"fd00:dead:beef::/64"}]}]'
PM
assert_eq "dual-stack mining_net → emits the resolved bridge name" "$(PATH="$NB/bin:$PATH" run_sourced "$NB" mining_net_ipv6_bridge)" "podman4"
cat >"$NB/bin/podman" <<'PM'
#!/usr/bin/env bash
echo '[{"name":"mining_net","subnets":[{"subnet":"fd00:dead:beef::/64"}]}]'
PM
assert_eq "v6 present but no interface → rc 3 (caller refuses, never installs a v4-only firewall)" "$(
    PATH="$NB/bin:$PATH" run_sourced "$NB" mining_net_ipv6_bridge >/dev/null
    echo $?
)" "3"

echo "== black-box: apply_tor_egress_firewall routes to nftables under podman (#855) =="
NFW="$SANDBOX/nfw"
mkdir -p "$NFW/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$NFW/bin/systemctl"
chmod +x "$NFW/bin/systemctl"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$NFW/bin/sudo"
cat >"$NFW/bin/nft" <<NFT
#!/usr/bin/env bash
if [ "\$1" = "-f" ]; then cat >>"$NFW/nft.ruleset"; else printf '%s\n' "\$*" >>"$NFW/nft.log"; fi
exit 0
NFT
printf '#!/usr/bin/env bash\necho "ILLEGAL iptables call on podman path: $*" >>"%s/nft.log"\nexit 1\n' "$NFW" >"$NFW/bin/iptables"
chmod +x "$NFW/bin/sudo" "$NFW/bin/nft" "$NFW/bin/iptables"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$NFW/.env"
: >"$NFW/nft.ruleset"
: >"$NFW/nft.log"
PITHEAD_ENGINE=podman PATH="$NFW/bin:$PATH" run_sourced "$NFW" apply_tor_egress_firewall >/dev/null 2>&1
assert_contains "podman path loads the nft table with the fail-closed DROP" "$(cat "$NFW/nft.ruleset")" "ip saddr 172.28.0.0/24 drop"
assert_contains "podman path hooks the chain at forward" "$(cat "$NFW/nft.ruleset")" "hook forward"
assert_not_contains "podman path never touches the orphaned DOCKER-USER chain" "$(cat "$NFW/nft.log")" "ILLEGAL iptables"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=false\n' >"$NFW/.env"
: >"$NFW/nft.ruleset"
PITHEAD_ENGINE=podman PATH="$NFW/bin:$PATH" run_sourced "$NFW" apply_tor_egress_firewall >/dev/null 2>&1
assert_eq "opt-out on the podman path loads no nft ruleset" "$(cat "$NFW/nft.ruleset")" ""
assert_not_contains "v4-only mining_net → the loaded ruleset carries no IPv6 rule" "$(
    printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$NFW/.env"
    : >"$NFW/nft.ruleset"
    PITHEAD_ENGINE=podman PATH="$NFW/bin:$PATH" run_sourced "$NFW" apply_tor_egress_firewall >/dev/null 2>&1
    cat "$NFW/nft.ruleset"
)" "ip6"

echo "== black-box: apply on a dual-stack mining_net loads the IPv6 backstop (#858) =="
printf '#!/usr/bin/env bash\necho '"'"'[{"name":"mining_net","network_interface":"podman4","subnets":[{"subnet":"172.28.0.0/24"},{"subnet":"fd00:dead:beef::/64"}]}]'"'"'\n' >"$NFW/bin/podman"
chmod +x "$NFW/bin/podman"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$NFW/.env"
: >"$NFW/nft.ruleset"
PITHEAD_ENGINE=podman PATH="$NFW/bin:$PATH" run_sourced "$NFW" apply_tor_egress_firewall >/dev/null 2>&1
dsrules="$(cat "$NFW/nft.ruleset")"
assert_contains "dual-stack apply keeps the v4 fail-closed DROP" "$dsrules" "ip saddr 172.28.0.0/24 drop"
assert_contains "dual-stack apply adds the bridge-scoped IPv6 DROP" "$dsrules" 'iifname "podman4" meta nfproto ipv6 drop'

echo "== black-box: apply REFUSES a v4-only firewall when mining_net has un-resolvable v6 (#858) =="
printf '#!/usr/bin/env bash\necho '"'"'[{"name":"mining_net","subnets":[{"subnet":"fd00:dead:beef::/64"}]}]'"'"'\n' >"$NFW/bin/podman"
: >"$NFW/nft.ruleset"
refuse_out="$(PITHEAD_ENGINE=podman PATH="$NFW/bin:$PATH" run_sourced "$NFW" apply_tor_egress_firewall 2>&1)"
assert_contains "warns loudly that it is REFUSING (fail-closed by refusal)" "$refuse_out" "REFUSING"
assert_eq "refusal loads no nft ruleset at all (no half-open v4-only firewall)" "$(cat "$NFW/nft.ruleset")" ""
rm -f "$NFW/bin/podman"

echo "== black-box: apply/remove_tor_egress_firewall via stubbed iptables (Docker path, #270) =="
FW="$SANDBOX/fw"
mkdir -p "$FW/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FW/bin/systemctl"
chmod +x "$FW/bin/systemctl"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$FW/bin/sudo"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/ipt.log"\n' "$FW" >"$FW/bin/iptables"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FW/bin/iptables-save"
printf '#!/usr/bin/env bash\n{ echo "restore $*"; cat; } >> "%s/ipt.log"\n' "$FW" >"$FW/bin/iptables-restore"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FW/bin/nft"
chmod +x "$FW"/bin/*
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$FW/.env"
: >"$FW/ipt.log"
PITHEAD_ENGINE=docker PATH="$FW/bin:$PATH" run_sourced "$FW" apply_tor_egress_firewall >/dev/null 2>&1
iptlog="$(cat "$FW/ipt.log" 2>/dev/null)"
assert_contains "installs the fail-closed clearnet DROP, tagged" "$iptlog" "-I DOCKER-USER 8 -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP"
assert_contains "exempts the Tor container" "$iptlog" "-m comment --comment pithead-tor-egress -s 172.28.0.25 -j ACCEPT"
assert_contains "loads them as one --noflush transaction (#2672)" "$iptlog" "restore -w --noflush"
assert_contains "pre-creates the DOCKER-USER chain (idempotently)" "$iptlog" "-N DOCKER-USER"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=false\n' >"$FW/.env"
: >"$FW/ipt.log"
PITHEAD_ENGINE=docker PATH="$FW/bin:$PATH" run_sourced "$FW" apply_tor_egress_firewall >/dev/null 2>&1
assert_eq "opt-out (network.tor_egress_firewall=false) installs no DROP" "$(grep -c 'DROP' "$FW/ipt.log" 2>/dev/null)" "0"
FF="$SANDBOX/fwfail"
mkdir -p "$FF/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FF/bin/systemctl"
chmod +x "$FF/bin/systemctl"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$FF/bin/sudo"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$IPT_LOG"\n' >"$FF/bin/iptables"
printf '#!/usr/bin/env bash\necho "-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP"\n' >"$FF/bin/iptables-save"
printf '#!/usr/bin/env bash\ncat >/dev/null; exit 1\n' >"$FF/bin/iptables-restore"
printf '#!/usr/bin/env bash\nprintf "nft %%s\\n" "$*" >>"$IPT_LOG"\n' >"$FF/bin/nft"
chmod +x "$FF"/bin/*
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$FF/.env"
: >"$FF/ipt.log"
fwfail_out="$(PITHEAD_ENGINE=docker PATH="$FF/bin:$PATH" IPT_LOG="$FF/ipt.log" run_sourced "$FF" apply_tor_egress_firewall 2>&1)"
fwfail_rc=$?
assert_rc "load failure degrades gracefully (stack still runs, rc 0)" "$fwfail_rc" "0"
assert_contains "load failure warns clearnet is NOT provably fail-closed" "$fwfail_out" "egress-apply:iptables-insert-failed"
assert_eq "load failure leaves the installed rules alone: no -D, no nft delete (#2672)" "$(grep -cE -- '-D |delete' "$FF/ipt.log")" "0"
RM="$SANDBOX/rm"
mkdir -p "$RM/bin"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$RM/bin/sudo"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/ipt.log"\n' "$RM" >"$RM/bin/iptables"
cat >"$RM/bin/iptables-save" <<'SAVE'
#!/usr/bin/env bash
cat <<'RULES'
-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP
-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.25 -j ACCEPT
-A DOCKER-USER -j RETURN
RULES
SAVE
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/nft.log"\nexit 0\n' "$RM" >"$RM/bin/nft"
chmod +x "$RM/bin/sudo" "$RM/bin/iptables" "$RM/bin/iptables-save" "$RM/bin/nft"
: >"$RM/ipt.log"
: >"$RM/nft.log"
PATH="$RM/bin:$PATH" run_sourced "$RM" remove_tor_egress_firewall >/dev/null 2>&1
rmlog="$(cat "$RM/ipt.log" 2>/dev/null)"
assert_contains "down removes the tagged clearnet DROP" "$rmlog" "-D DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP"
assert_contains "down removes the tagged Tor-exempt ACCEPT" "$rmlog" "-D DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.25 -j ACCEPT"
assert_not_contains "down leaves foreign DOCKER-USER rules untouched" "$rmlog" "RETURN"
assert_contains "down also drops the nft egress table (netavark backend)" "$(cat "$RM/nft.log" 2>/dev/null)" "delete table inet pithead_egress"

# shellcheck source=tests/stack/fixtures/tor-egress/lifecycle-order.sh
source "$ROOT/tests/stack/fixtures/tor-egress/lifecycle-order.sh"

echo "== unit: clearnet initial sync helpers (#183) =="
for v in true 1 YES On TRUE; do
    assert_eq "normalize_bool '$v' => true" "$(run_sourced "$SANDBOX" normalize_bool "$v")" "true"
done
for v in false 0 no off "" garbage; do
    assert_eq "normalize_bool '${v:-<empty>}' => false" "$(run_sourced "$SANDBOX" normalize_bool "$v")" "false"
done
MONT="$SANDBOX/mon-clearnet.conf"
cp "$ROOT/build/monero/bitmonero.conf.template" "$MONT"
# shellcheck disable=SC1090
(
    export PITHEAD_TEST_SOURCE=1
    source "$ROOT/build/monero/entrypoint.sh"
    apply_clearnet_initial_sync "$MONT"
)
case "$(grep -E '^proxy=' "$MONT" || true)" in
"") ok "monero clearnet: P2P proxy= line stripped (#183)" ;;
*) bad "monero clearnet: P2P proxy= line stripped (#183)" "still present" ;;
esac
assert_contains "monero clearnet: tx-proxy stays on Tor (#183)" "$(cat "$MONT")" "tx-proxy=tor"
assert_contains "monero clearnet: out-peers=32 (p2pool v4.18 rec)" "$(cat "$MONT")" "out-peers=32"
assert_contains "monero clearnet: xmrvsbeast priority node (v4.18)" "$(cat "$MONT")" "add-priority-node=p2pmd.xmrvsbeast.com:18080"
assert_contains "monero clearnet: hashvault priority node (v4.18)" "$(cat "$MONT")" "add-priority-node=nodes.hashvault.pro:18080"
assert_contains "monero default: Tor P2P proxy present (#183)" "$(cat "$ROOT/build/monero/bitmonero.conf.template")" 'proxy=${NETWORK_PREFIX}.25:9050'
assert_contains "monero default: out-peers config-driven for Tor (#183/#595)" "$(cat "$ROOT/build/monero/bitmonero.conf.template")" 'out-peers=${MONERO_OUT_PEERS}'
assert_contains "compose passes MONERO_CLEARNET_SYNC to monerod (#183)" "$(cat "$ROOT/docker-compose.yml")" 'MONERO_CLEARNET_SYNC=${MONERO_CLEARNET_SYNC'
assert_contains "compose passes TARI_CLEARNET_SYNC to tari (#183)" "$(cat "$ROOT/docker-compose.yml")" 'TARI_CLEARNET_SYNC=${TARI_CLEARNET_SYNC'
assert_contains "compose passes MONERO_OUT_PEERS to monerod (#595)" "$(cat "$ROOT/docker-compose.yml")" 'MONERO_OUT_PEERS=${MONERO_OUT_PEERS'

mono_active() { (
    export PITHEAD_TEST_SOURCE=1 MONERO_CLEARNET_SYNC="$1" CLEARNET_MARKER="$2"
    source "$ROOT/build/monero/entrypoint.sh"
    clearnet_sync_active
); }
if mono_active true "$SANDBOX/absent-marker"; then ok "monero clearnet ACTIVE when flag on + no marker (#234)"; else bad "monero clearnet active gate (#234)" "expected active"; fi
: >"$SANDBOX/mono.marker"
if mono_active true "$SANDBOX/mono.marker"; then bad "monero clearnet inactive once marker present (#234)" "still active"; else ok "monero clearnet INACTIVE once marker present → Tor (#234)"; fi
if mono_active false "$SANDBOX/absent-marker"; then bad "monero clearnet off when flag off (#234)" "active with flag off"; else ok "monero clearnet OFF when flag off (#234)"; fi

TARISRC="$SANDBOX/tari-src.toml"
cp "$ROOT/build/tari/config.toml.template" "$TARISRC"
# shellcheck disable=SC1090
(
    export PITHEAD_TEST_SOURCE=1 TARI_CLEARNET_SYNC=true CLEARNET_MARKER="$SANDBOX/absent-marker"
    source "$ROOT/build/tari/entrypoint.sh"
    render_tari_runtime_config "$TARISRC" "$SANDBOX/tari-rt.toml"
)
assert_contains "tari entrypoint clearnet: TCP transport (#234)" "$(cat "$SANDBOX/tari-rt.toml")" 'type = "tcp"'
assert_contains "tari entrypoint clearnet: DNS seed enabled (#234)" "$(cat "$SANDBOX/tari-rt.toml")" 'dns_seeds = ["seeds.tari.com"]'
: >"$SANDBOX/tari.marker"
# shellcheck disable=SC1090
(
    export PITHEAD_TEST_SOURCE=1 TARI_CLEARNET_SYNC=true CLEARNET_MARKER="$SANDBOX/tari.marker"
    source "$ROOT/build/tari/entrypoint.sh"
    render_tari_runtime_config "$TARISRC" "$SANDBOX/tari-rt2.toml"
)
assert_contains "tari entrypoint marker→Tor: transport Tor SOCKS (#234)" "$(cat "$SANDBOX/tari-rt2.toml")" 'type = "socks5"'
assert_contains "tari entrypoint marker→Tor: DNS seeds empty (#234)" "$(cat "$SANDBOX/tari-rt2.toml")" "dns_seeds = []"
assert_contains "tari entrypoint never mutates the canonical config (#234)" "$(cat "$TARISRC")" 'type = "socks5"'
assert_contains "compose mounts clearnet-state into monerod (#234)" "$(cat "$ROOT/docker-compose.yml")" ':/clearnet-state:ro'
assert_contains "compose wires the tari wrapper entrypoint (#234)" "$(cat "$ROOT/docker-compose.yml")" '/var/tari/config/entrypoint.sh'

echo "== node configs: no clearnet DNS egress (#161 monerod, #162 tari) =="
MONC="$ROOT/build/monero/bitmonero.conf.template"
TARC="$ROOT/build/tari/config.toml.template"
case "$(cat "$MONC")" in
*xmrvsbeast.com:18080* | *nodes.hashvault.pro*) bad "monerod: priority-node hostnames dropped (#161)" "still present" ;;
*) ok "monerod: priority-node hostnames dropped (#161)" ;;
esac
case "$(grep -E '^enforce-dns-checkpointing' "$MONC" || true)" in
"") ok "monerod: enforce-dns-checkpointing removed (#161)" ;;
*) bad "monerod: enforce-dns-checkpointing removed (#161)" "still present" ;;
esac
assert_contains "monerod: DNS checkpoints disabled (#161)" "$(cat "$MONC")" "disable-dns-checkpoints=1"
assert_contains "monerod: update check disabled (#161)" "$(cat "$MONC")" "check-updates=disabled"
assert_contains "tari: DNS seeds disabled (#162)" "$(cat "$TARC")" "dns_seeds = []"
assert_eq "tari: transport is the Tor SOCKS proxy (#2653)" "$(grep -E '^type = ' "$TARC")" 'type = "socks5"'
assert_eq "tari: SOCKS proxy is the stack tor container (#2653)" "$(grep -E '^proxy_address = ' "$TARC")" 'proxy_address = "/ip4/172.28.0.25/tcp/9050"'
assert_eq "tari: in-process Tor (libtor) disabled (#2653)" "$(grep -E '^use_libtor = ' "$TARC")" "use_libtor = false"
case "$(grep -E '::/ip4/|::/ip6/' "$TARC" || true)" in
"") ok "tari: peer_seeds are onion-only (#162)" ;;
*) bad "tari: peer_seeds are onion-only (#162)" "clearnet /ip4//ip6/ peer seeds present" ;;
esac
case "$(grep -E 'check_for_updates' "$TARC" || true)" in
"") ok "tari: check_for_updates dropped from gRPC allow-list (#162)" ;;
*) bad "tari: check_for_updates dropped from gRPC allow-list (#162)" "still present" ;;
esac
TARI_SVC="$(awk '/^  tari:/{f=1;print;next} f&&/^  [a-z]/{f=0} f' "$ROOT/docker-compose.yml")"
case "$TARI_SVC" in
*1.1.1.1* | *8.8.8.8*) bad "tari: clearnet DNS resolvers removed from compose (#162)" "1.1.1.1/8.8.8.8 present" ;;
*) ok "tari: clearnet DNS resolvers removed from compose (#162)" ;;
esac
assert_contains "tari: resolver pointed at dead local sinkhole (#162)" "$TARI_SVC" "127.0.0.1"

echo "== black-box: tor.auto_heal renders to .env (#424) =="
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tor.auto_heal defaults to off" "$(run_sourced "$V" env_get_file "$V/.env" TOR_AUTO_HEAL)" "false"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "tor":{"auto_heal":true}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tor.auto_heal opt-in renders true" "$(run_sourced "$V" env_get_file "$V/.env" TOR_AUTO_HEAL)" "true"

echo "== black-box: clearnet initial sync render (#183) =="
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "monero clearnet off by default" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_CLEARNET_SYNC)" "false"
assert_eq "tari clearnet off by default" "$(run_sourced "$V" env_get_file "$V/.env" TARI_CLEARNET_SYNC)" "false"
assert_contains "tari default: Tor SOCKS transport" "$(cat "$V/build/tari/config.toml")" 'type = "socks5"'
assert_contains "tari default: DNS seeds empty" "$(cat "$V/build/tari/config.toml")" "dns_seeds = []"
assert_contains "tari default: advertises onion" "$(cat "$V/build/tari/config.toml")" "/onion3/"

seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","clearnet_initial_sync":true}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "network":{"tor_egress_firewall":false}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "monero clearnet flag propagated true" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_CLEARNET_SYNC)" "true"
assert_eq "tari clearnet still false" "$(run_sourced "$V" env_get_file "$V/.env" TARI_CLEARNET_SYNC)" "false"
assert_contains "tari stays Tor when only monero is clearnet" "$(cat "$V/build/tari/config.toml")" 'type = "socks5"'
assert_contains "apply preview warns clearnet exposure" "$out" "CLEARNET"

seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","clearnet_initial_sync":true}, "network":{"tor_egress_firewall":false}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tari clearnet flag propagated true" "$(run_sourced "$V" env_get_file "$V/.env" TARI_CLEARNET_SYNC)" "true"
assert_contains "tari host-render stays Tor even with flag on (#234)" "$(cat "$V/build/tari/config.toml")" 'type = "socks5"'
assert_contains "tari host-render keeps DNS seeds empty (#234)" "$(cat "$V/build/tari/config.toml")" "dns_seeds = []"
assert_contains "tari host-render still advertises the onion (#234)" "$(cat "$V/build/tari/config.toml")" "/onion3/"

seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","clearnet_initial_sync":"yes"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "network":{"tor_egress_firewall":false}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "monero clearnet truthy 'yes' => true" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_CLEARNET_SYNC)" "true"

seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "doctor: OK when Tor-only (#183)" "$(cd "$V" && PATH="$V/bin:$PATH" ./pithead doctor 2>&1)" "Tor-only"

echo "== black-box: selected clearnet sync with firewall on (#2678) =="
# shellcheck source=tests/stack/fixtures/tor-egress/validation-sandbox.sh
source "$ROOT/tests/stack/fixtures/tor-egress/validation-sandbox.sh" "$V"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","clearnet_initial_sync":true}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "monero clearnet + firewall on: apply succeeds" "$?" "0"
assert_eq "monero chosen sync reaches the daemon" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_CLEARNET_SYNC)" "true"
assert_contains "monero chosen sync reports IP exposure" "$out" "CLEARNET"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","clearnet_initial_sync":true}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari clearnet + firewall on: apply succeeds" "$?" "0"
assert_eq "tari chosen sync reaches the daemon" "$(run_sourced "$V" env_get_file "$V/.env" TARI_CLEARNET_SYNC)" "true"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"

dr273() { cd "$V" && P2POOL_PROC1="$1" PATH="$V/bin:$PATH" ./pithead doctor 2>&1; }
assert_contains "doctor FAILs when p2pool isn't on Tor — stale image (#273)" \
    "$(dr273 'p2pool --host 172.28.0.26 --rpc-port 18081 --mini')" "STALE p2pool image"
assert_contains "doctor OK when p2pool IS routed over Tor (#273)" \
    "$(dr273 'p2pool --host 172.28.0.26 --mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor')" "routes outbound sidechain P2P via Tor"

TOR_ENTRY="$ROOT/build/tor/entrypoint.sh"
tor_torrc() {
    local d
    mk_tmpdir d
    printf '#!/bin/sh\ncat "%s"\n' "$d/torrc" >"$d/tor"
    chmod +x "$d/tor"
    PATH="$d:$PATH" DASHBOARD_ONION_ENABLED="$1" COMPOSE_PROFILES="${2-local_node,local_tari}" NETWORK_PREFIX=10.9.0 P2POOL_PORT="${3-37888}" \
        TORRC_TEMPLATE="$ROOT/build/tor/torrc.template" TORRC_OUT="$d/torrc" sh "$TOR_ENTRY"
    rm -rf "$d"
}
assert_eq "tor entrypoint keeps /tmp/torrc as its container default (#1104)" \
    "$(grep -c '^: "${TORRC_OUT:=/tmp/torrc}"$' "$TOR_ENTRY")" "1"
assert_eq "tor entrypoint writes NO bare /tmp/torrc outside that default (#1104)" \
    "$(grep -vE '^\s*#' "$TOR_ENTRY" | grep -cF '/tmp/torrc')" "1"
tor_onion_on="$(tor_torrc true)"
assert_contains "tor entrypoint: dashboard HiddenService appended when enabled (#343)" \
    "$tor_onion_on" "HiddenServiceDir /var/lib/tor/dashboard/"
assert_contains "tor entrypoint: onion vhost targets the bridge gateway .1 (#343)" \
    "$tor_onion_on" "HiddenServicePort 80 10.9.0.1:80"
assert_contains "tor entrypoint: onion also exposes :443 for the Tor-Browser https upgrade (#343)" \
    "$tor_onion_on" "HiddenServicePort 443 10.9.0.1:443"
assert_not_contains "tor entrypoint: no dashboard onion when disabled (default off) (#343)" \
    "$(tor_torrc false)" "Dashboard Hidden Service"

tor_both_local="$(tor_torrc false local_node,local_tari)"
assert_contains "tor entrypoint: Monero HS present when local_node is active (#103)" \
    "$tor_both_local" "HiddenServiceDir /var/lib/tor/monero/"
assert_contains "tor entrypoint: Monero HS targets the node on the moved prefix (#103/#180)" \
    "$tor_both_local" "HiddenServicePort 18080 10.9.0.26:18084"
assert_contains "tor entrypoint: Tari HS present when local_tari is active (#103)" \
    "$tor_both_local" "HiddenServiceDir /var/lib/tor/tari/"
assert_contains "tor entrypoint: Tari HS targets the node on the moved prefix (#103/#180)" \
    "$tor_both_local" "HiddenServicePort 18189 10.9.0.27:18189"
tor_remote_tari="$(tor_torrc false local_node)"
assert_contains "tor entrypoint: Monero HS still present with only local_node (#103)" \
    "$tor_remote_tari" "HiddenServiceDir /var/lib/tor/monero/"
assert_not_contains "tor entrypoint: no Tari HS when local_tari is omitted (remote tari, #103)" \
    "$tor_remote_tari" "/var/lib/tor/tari/"
tor_both_remote="$(tor_torrc false "")"
assert_not_contains "tor entrypoint: no Monero HS with no profiles (remote monero, #103)" \
    "$tor_both_remote" "/var/lib/tor/monero/"
assert_not_contains "tor entrypoint: no Tari HS with no profiles (remote tari, #103)" \
    "$tor_both_remote" "/var/lib/tor/tari/"
assert_contains "tor entrypoint: P2Pool HS is unconditional — p2pool always runs (#103)" \
    "$tor_both_remote" "HiddenServiceDir /var/lib/tor/p2pool/"
for pool_port in 37889 37888 37890; do
    assert_contains "tor entrypoint: P2Pool onion follows selected port (#2936)" \
        "$(tor_torrc false "" "$pool_port")" "HiddenServicePort $pool_port 10.9.0.28:$pool_port"
done
assert_contains "Monero anonymous listener accepts Tor on the bridge (#2936)" \
    "$(cat "$ROOT/build/monero/bitmonero.conf.template")" \
    'anonymous-inbound=${MONERO_ONION_ADDRESS}:18080,0.0.0.0:18084'
unset tor_both_local tor_remote_tari tor_both_remote

echo "== unit: onion provisioning follows node mode (#103) =="
ONP="$SANDBOX/onion-prov"
make_host_tool_stubs "$ONP/bin" systemctl
prov_probe() {
    (
        cd "$ONP" || exit
        export PITHEAD_UNIT_DIR="$ONP/units" PATH="$ONP/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        apply_tor_egress_firewall() { :; }
        lan_guard_prepare_up() { :; }
        : >asked
        log() { :; }
        docker() { :; }
        resolve_pull_policy() { echo missing; }
        provision_onion_client_auth() { :; }
        provision_dashboard_onion() { :; }
        wait_for_onion() {
            printf '%s,' "$1" >>asked
            echo "$1.onion"
        }
        MONERO_MODE="$1"
        TARI_MODE="$2"
        MONERO_ONION=placeholder
        TARI_ONION=placeholder
        P2POOL_ONION=placeholder
        provision_tor
        printf '%s|%s|%s|%s' "$(cat asked)" "$MONERO_ONION" "$TARI_ONION" "$P2POOL_ONION"
    )
}
assert_eq "provision_tor waits for both node onions when both nodes are local (#103)" \
    "$(prov_probe local local)" "p2pool,monero,tari,|monero.onion|tari.onion|p2pool.onion"
assert_eq "provision_tor skips a remote node's onion and leaves it a placeholder (#103)" \
    "$(prov_probe remote remote)" "p2pool,|placeholder|placeholder|p2pool.onion"
assert_eq "provision_tor waits for the local node only in a mixed setup (#103)" \
    "$(prov_probe local remote)" "p2pool,monero,|monero.onion|placeholder|p2pool.onion"

node_onion_probe() {
    (
        cd "$ONP" || exit
        export PITHEAD_UNIT_DIR="$ONP/units" PATH="$ONP/bin:$PATH"
        [ "${5:-}" != source ] || { mkdir -p dashboard && : >dashboard/Dockerfile; }
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        apply_tor_egress_firewall() { :; }
        lan_guard_prepare_up() { :; }
        : >asked
        : >dockerlog
        : >renders
        log() { :; }
        restore_recreate_names() { :; }
        lan_guard_watched_ports() { :; }
        docker() {
            [ "$1" != ps ] || return 0
            printf '%s ' "$*" >>dockerlog
        }
        render_env() { printf 'x' >>renders; }
        wait_for_onion() {
            printf '%s,' "$1" >>asked
            echo "$1.onion"
        }
        # shellcheck disable=SC2034
        MONERO_MODE="$1"
        MONERO_ONION="$2"
        # shellcheck disable=SC2034
        TARI_MODE="$3"
        TARI_ONION="$4"
        provision_node_onions
        printf '%s|%s|%s|%s|%s' "$(cat dockerlog)" "$(cat asked)" "$MONERO_ONION" "$TARI_ONION" "$(cat renders)"
    )
}
assert_eq "provision_node_onions is a free no-op once every local node has its onion (#103)" \
    "$(node_onion_probe local mona.onion local taria.onion)" "||mona.onion|taria.onion|"
assert_eq "provision_node_onions ignores a remote node with no onion (#103)" \
    "$(node_onion_probe remote placeholder remote placeholder)" "||placeholder|placeholder|"
assert_eq "provision_node_onions mints + captures the onion of a node that just went local (#103)" \
    "$(node_onion_probe local placeholder remote placeholder)" "compose up --no-build -d tor |monero,|monero.onion|placeholder|x"
assert_eq "provision_node_onions treats an empty address as missing, and re-renders once (#103)" \
    "$(node_onion_probe local '' local '')" "compose up --no-build -d tor |monero,tari,|monero.onion|tari.onion|x"
assert_eq "source compose up preserves development builds (#1967)" \
    "$(node_onion_probe local placeholder remote placeholder source)" "compose up -d tor |monero,|monero.onion|placeholder|x"
unset ONP prov_probe node_onion_probe
