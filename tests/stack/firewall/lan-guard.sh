# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# LAN-only sources for the node ports the *_lan_access switches publish (#2616): the rule is rendered
# with the LAN set only, compose never publishes on 0.0.0.0 unless the rule is live (the loopback
# fallback), doctor tells exposed from held, and every publish of the three ports stays an explicit
# IPv4 bind, so the IPv4-only rule covers it. The live half, a non-private source refused on the
# bench, is tests/integration/lib/run-state.sh.
# Sourced by tests/stack/run.sh.

LGD="$SANDBOX/lan-guard"
mkdir -p "$LGD/bin"
cat >"$LGD/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -n | -H | -E) shift ;; *) break ;; esac; done
exec "$@"
SUDO
# iptables: the chain and our jumps read back only when LG_LIVE=1, so "restore exited zero" and
# "the rule is live" can disagree.
cat >"$LGD/bin/iptables" <<'IPT'
#!/usr/bin/env bash
case "$*" in
"-S") exit 0 ;;
"-S PITHEAD-LAN")
    [ "${LG_LIVE:-0}" = 1 ] || exit 1
    printf '%s\n' '-N PITHEAD-LAN' '-A PITHEAD-LAN -s 10.0.0.0/8 -j RETURN' '-A PITHEAD-LAN -j DROP'
    ;;
"-S DOCKER-USER")
    echo '-N DOCKER-USER'
    [ -n "${LG_FOREIGN:-}" ] && echo "$LG_FOREIGN"
    [ "${LG_LIVE:-0}" = 1 ] && echo '-A DOCKER-USER -p tcp -m tcp --dport 18142 -m conntrack --ctstate NEW -m comment --comment "pithead-lan-guard" -j PITHEAD-LAN'
    exit 0
    ;;
"-S FORWARD") echo '-A FORWARD -j DOCKER-USER' ;;
esac
exit 0
IPT
cat >"$LGD/bin/iptables-restore" <<'IPR'
#!/usr/bin/env bash
cat >"$LG_RESTORE"
exit "${LG_RESTORE_RC:-0}"
IPR
cat >"$LGD/bin/nft" <<'NFT'
#!/usr/bin/env bash
case "$*" in
-f*) cat >"$LG_RESTORE" ;;
"list tables") exit 0 ;;
*"list table inet pithead_lan")
    [ "${LG_LIVE:-0}" = 1 ] || exit 1
    printf '%s\n' '{"nftables":[{"chain":{"name":"forward","hook":"forward"}},{"rule":{"chain":"forward","expr":[{"match":{"right":{"set":[18081,18142]}}},{"drop":null}]}}]}'
    ;;
esac
exit 0
NFT
# docker: `compose up` records the bind it was handed; `ps`/`port` answer the doctor rows.
cat >"$LGD/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1 ${2:-}" in
"compose up"*) echo "compose-bind=${TARI_GRPC_BIND:-from-env-file}" >>"$LG_COMPOSE" ;;
"ps "*) echo cid123 ;;
"port "*) echo "${LG_PUBLISHED:-0.0.0.0}:18142" ;;
esac
exit 0
DOCKER
chmod +x "$LGD/bin/"*
export LG_RESTORE="$LGD/restore.in" LG_COMPOSE="$LGD/compose.log"
printf 'TARI_GRPC_BIND=0.0.0.0\nMONERO_RPC_BIND=127.0.0.1\nMONERO_ZMQ_BIND=127.0.0.1\n' >"$LGD/.env"
lg() { (cd "$LGD" && PATH="$LGD/bin:$PATH" bash -c "source '$STACK'; $1" 2>&1); }

echo "== the rule admits loopback, RFC1918 and CGNAT only, and drops the rest (#2616) =="
lg_out="$(printf '%s\n' '-A DOCKER-USER -p tcp -m tcp --dport 18081 -m comment --comment pithead-lan-guard -j PITHEAD-LAN' |
    run_sourced "$LGD" render_lan_guard_iptables 18142)"
assert_eq "iptables: the chain RETURNs exactly the LAN set, then DROPs" \
    "$(grep -- '-A PITHEAD-LAN' <<<"$lg_out" | tr '\n' '|')" \
    "-A PITHEAD-LAN -s 127.0.0.0/8 -j RETURN|-A PITHEAD-LAN -s 10.0.0.0/8 -j RETURN|-A PITHEAD-LAN -s 172.16.0.0/12 -j RETURN|-A PITHEAD-LAN -s 192.168.0.0/16 -j RETURN|-A PITHEAD-LAN -s 100.64.0.0/10 -j RETURN|-A PITHEAD-LAN -j DROP|"
assert_contains "iptables: a NEW connection to the published port jumps to the chain" "$lg_out" \
    "-I DOCKER-USER 1 -p tcp -m tcp --dport 18142 -m conntrack --ctstate NEW -m comment --comment pithead-lan-guard -j PITHEAD-LAN"
assert_contains "iptables: a port no longer published loses its jump in the same commit" "$lg_out" "-D DOCKER-USER -p tcp -m tcp --dport 18081"
assert_eq "iptables: one commit, so no packet sees a half-built set" "$(tail -n 1 <<<"$lg_out")" "COMMIT"
lg_out="$(run_sourced "$LGD" render_lan_guard_nft 18081 18142)"
assert_contains "nft: drop NEW connections to the ports from outside the LAN set" "$lg_out" \
    "tcp dport { 18081, 18142 } ct state new ip saddr != { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10 } drop"
assert_contains "nft: its own table, hooked at forward" "$lg_out" "type filter hook forward priority -5"

echo "== compose never publishes on 0.0.0.0 unless the rule is live (#2616) =="
: >"$LG_COMPOSE"
lg_out="$(LG_LIVE=1 lg 'compose_up -d')"
assert_contains "installed and read back: apply says so" "$lg_out" "LAN-only sources enforced on port(s) 18142"
assert_contains "installed: only the published port gets a jump" "$(cat "$LG_RESTORE")" "--dport 18142"
assert_not_contains "installed: a loopback-bound port gets none" "$(cat "$LG_RESTORE")" "--dport 18081"
assert_eq "installed: compose publishes the .env bind" "$(cat "$LG_COMPOSE")" "compose-bind=from-env-file"
: >"$LG_COMPOSE"
lg_out="$(LG_LIVE=0 lg 'compose_up -d')"
assert_contains "restore exits 0 but the rule is not live: named" "$lg_out" "lan-guard:not-installed"
assert_eq "...and compose is handed 127.0.0.1, not 0.0.0.0" "$(cat "$LG_COMPOSE")" "compose-bind=127.0.0.1"
: >"$LG_COMPOSE"
lg_out="$(LG_LIVE=1 LG_RESTORE_RC=1 lg 'compose_up -d')"
assert_contains "the install itself fails (no root): the reason is named" "$lg_out" "could not enforce"
assert_eq "...and compose is handed 127.0.0.1" "$(cat "$LG_COMPOSE")" "compose-bind=127.0.0.1"
: >"$LG_COMPOSE"
lg_out="$(PITHEAD_ENGINE=podman LG_LIVE=0 lg 'compose_up -d')"
assert_eq "podman: an nft table that does not read back holds the port on 127.0.0.1" "$(cat "$LG_COMPOSE")" "compose-bind=127.0.0.1"
lg_out="$(PITHEAD_ENGINE=podman LG_LIVE=1 lg 'apply_lan_guard')"
assert_contains "podman: a table with the drop and the port is enforced" "$lg_out" "LAN-only sources enforced"
rm -f "$LG_RESTORE"
cp "$LGD/.env" "$LGD/.env.on"
printf 'TARI_GRPC_BIND=127.0.0.1\n' >"$LGD/.env"
lg_out="$(lg apply_lan_guard)"
mv "$LGD/.env.on" "$LGD/.env"
assert_eq "every switch off: nothing is installed and nothing is said" "$lg_out" ""
assert_eq "...and no firewall command runs" "$(test -e "$LG_RESTORE" && echo ran || echo none)" "none"

echo "== doctor tells a port held on loopback from one exposed without the rule (#2616) =="
lg_out="$(LG_LIVE=1 lg check_lan_guard)"
assert_contains "rule live: OK" "$lg_out" "LAN-only sources enforced on port(s) 18142"
lg_out="$(LG_LIVE=0 LG_PUBLISHED=0.0.0.0 lg check_lan_guard)"
assert_contains "rule missing and the port on 0.0.0.0: FAIL" "$lg_out" "published on every interface with NO LAN-only source rule"
lg_out="$(LG_LIVE=0 LG_PUBLISHED=127.0.0.1 lg check_lan_guard)"
assert_contains "rule missing and the port on loopback: says it is held, and why" "$lg_out" "held on 127.0.0.1"
assert_contains "...naming the reason" "$lg_out" "not in the live ruleset"
lg_out="$(LG_LIVE=1 LG_FOREIGN='-A DOCKER-USER -j ACCEPT' LG_PUBLISHED=0.0.0.0 lg check_lan_guard)"
assert_contains "a foreign ACCEPT above our jumps is not called enforced" "$lg_out" "not ours accepts traffic above it"

echo "== every publish of 18081, 18083 and 18142 is an explicit IPv4 bind (#2616) =="
# The rule is IPv4 only. `[::]:P:P` or a bare `P:P` would also listen on IPv6, where nothing limits
# the source, so a change of either shape, or of an engine default behind one, has to fail here.
for kp in MONERO_RPC_BIND:18081 MONERO_ZMQ_BIND:18083 TARI_GRPC_BIND:18142; do
    k="${kp%%:*}" p="${kp#*:}"
    assert_eq "compose publishes $p only as \${$k:-127.0.0.1}" \
        "$(grep -E "^ *- *\"?[^ \"=]*\b$p(:$p)?(/tcp)?\"? *$" "$ROOT/docker-compose.yml" | sed 's/^ *//' | tr '\n' '|')" \
        "- \"\${$k:-127.0.0.1}:$p:$p\"|"
    assert_eq "quadlet publishes $p only from $k" \
        "$(grep -E "PublishPort=.*:$p(:|$)" "$ROOT/lib/pithead/36-quadlet-units.sh" | tr '\n' '|')" \
        "PublishPort=\$(_qenv $k):$p:$p|"
done
assert_eq "render_env assigns the three binds only IPv4 literals" \
    "$(grep -E '(rpc|zmq|tari_grpc)_bind="' "$ROOT/lib/pithead/33-render-env.sh" | grep -oE '_bind="[^"]*"' | sort -u | tr '\n' '|')" \
    '_bind="0.0.0.0"|_bind="127.0.0.1"|'
