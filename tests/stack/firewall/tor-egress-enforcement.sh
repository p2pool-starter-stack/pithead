# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

path_without_sbin() {
    local d out="" IFS=:
    for d in $PATH; do
        case "$d" in *sbin*) ;; *) out="${out:+$out:}$d" ;; esac
    done
    printf '%s' "$out"
}

EGV="$SANDBOX/egress-enforcement"
mkdir -p "$EGV/bin" "$EGV/bin-nonft"
printf '#!/usr/bin/env bash\nexit 0\n' >"$EGV/bin/systemctl"
chmod +x "$EGV/bin/systemctl"
cat >"$EGV/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -n | -H | -E) shift ;; *) break ;; esac; done
exec "$@"
SUDO
cat >"$EGV/bin/nft" <<'NFT'
#!/usr/bin/env bash
case "$*" in
-f*)
    cat >>"${NFT_RULESET:-/dev/null}"
    exit 0
    ;;
"list tables")
    echo "table inet netavark"
    exit 0
    ;;
*"list table inet pithead_egress")
    # JSON: the check reads `nft -j` and asks whether the drop is a rule IN the forward-hooked
    # chain. A text ruleset is no longer what the code consumes, so a text stub tests nothing.
    [ "${NFT_LIVE:-0}" = 1 ] || exit 1
    printf '%s\n' '{"nftables":[{"chain":{"name":"forward","hook":"forward","type":"filter"}},{"rule":{"chain":"forward","expr":[{"match":{"left":{"payload":{"protocol":"ip","field":"saddr"}},"op":"==","right":{"prefix":{"addr":"172.28.0.0","len":24}}}},{"drop":null}]}}]}'
    exit 0
    ;;
esac
exit 0
NFT
cat >"$EGV/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
name=$(printf '%s' "$*" | sed -n 's/.*name=\^\([a-z0-9-]*\)\$.*/\1/p')
case " ${RUNNING_CONTAINERS:-} " in *" $name "*) echo cid123 ;; esac
exit 0
DOCKER
chmod +x "$EGV/bin/sudo" "$EGV/bin/nft" "$EGV/bin/docker"
cp "$EGV/bin/sudo" "$EGV/bin/docker" "$EGV/bin/systemctl" "$EGV/bin-nonft/"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$EGV/.env"

echo "== the #858 refusal must survive errexit, the way production runs it (#2059) =="
printf '#!/usr/bin/env bash\necho '"'"'[{"name":"mining_net","subnets":[{"subnet":"fd00:dead:beef::/64"}]}]'"'"'\n' >"$EGV/bin/podman"
chmod +x "$EGV/bin/podman"
: >"$EGV/nft.ruleset"
ee_out="$(cd "$EGV" && PITHEAD_ENGINE=podman PATH="$EGV/bin:$PATH" NFT_RULESET="$EGV/nft.ruleset" bash -c "source '$STACK'; apply_tor_egress_firewall" 2>&1)"
assert_rc "the refusal returns cleanly under errexit (it no longer dies at the assignment)" "$?" "0"
assert_contains "the refusal under errexit still reaches its REFUSING warning" "$ee_out" "REFUSING"
assert_eq "the refusal under errexit loads no ruleset (no half-open v4-only firewall)" "$(cat "$EGV/nft.ruleset")" ""
rm -f "$EGV/bin/podman"

echo "== apply only CLAIMS enforcement after reading the rules back (#2059) =="
egv_out="$(PITHEAD_ENGINE=podman NFT_LIVE=0 PATH="$EGV/bin:$PATH" run_sourced "$EGV" apply_tor_egress_firewall 2>&1)"
assert_not_contains "a load that did not land never claims 'Tor-only egress enforced'" "$egv_out" "Tor-only egress enforced"
assert_contains "...and names which exit it took, for the bounded journal excerpt" "$egv_out" "egress-apply:verify-absent"
egv_out="$(PITHEAD_ENGINE=podman NFT_LIVE=1 PATH="$EGV/bin:$PATH" run_sourced "$EGV" apply_tor_egress_firewall 2>&1)"
assert_contains "a verified install DOES claim enforcement" "$egv_out" "Tor-only egress enforced"
assert_not_contains "...and carries no egress-apply failure token" "$egv_out" "egress-apply:"

echo "== a missing backend tool is NAMED by apply and FAILED by doctor (#2059) =="
assert_eq "harness: nft really is absent from the no-nft PATH" \
    "$(PATH="$EGV/bin-nonft:$(path_without_sbin)" command -v nft 2>/dev/null || echo absent)" "absent"
notool_out="$(PITHEAD_ENGINE=podman PATH="$EGV/bin-nonft:$(path_without_sbin)" run_sourced "$EGV" apply_tor_egress_firewall 2>&1)"
assert_contains "no nft on PATH -> apply names that exit" "$notool_out" "egress-apply:nft-missing"
assert_not_contains "no nft on PATH -> apply never claims enforcement" "$notool_out" "Tor-only egress enforced"
notool_out="$(PITHEAD_ENGINE=podman RUNNING_CONTAINERS="tor" PATH="$EGV/bin-nonft:$(path_without_sbin)" run_sourced "$EGV" check_egress_firewall_installed 2>&1)"
assert_contains "doctor (podman): no nft binary -> FAIL, not a skip" "$notool_out" "CANNOT be enforced"
assert_not_contains "doctor (podman): a missing tool is not reported as a sudo problem" "$notool_out" "passwordless sudo"

echo "== the iptables backend proves REACHABILITY, not just presence (#855 inside the verifier) =="
IPJ="$EGV/ipj"
mkdir -p "$IPJ"
cp "$EGV/bin/sudo" "$EGV/bin/docker" "$EGV/bin/systemctl" "$IPJ/"
cat >"$IPJ/iptables" <<'IPT'
#!/usr/bin/env bash
case "$*" in
"-S DOCKER-USER")
    echo '-A DOCKER-USER -m comment --comment "pithead-tor-egress" -s 172.28.0.0/24 -j DROP'
    exit 0
    ;;
"-S FORWARD")
    [ "${JUMP:-0}" = 1 ] && echo '-A FORWARD -j DOCKER-USER'
    # `exec`, and the bulk, are BOTH load-bearing — do not tidy either away.
    #
    # A `grep -q` that matches on line 1 exits while the producer is still writing; the producer
    # takes SIGPIPE; under `pipefail` the pipeline yields 141, so a guard written as
    # `producer | grep -q ... || return N` fires on a SUCCESSFUL match. That cost a false FAIL on a
    # live Docker host, where the real FORWARD chain is long.
    #
    # Reproducing it needs the stub to BE the producer, the way iptables is. A first cut wrote the
    # bulk and then `exit 0`: SIGPIPE killed the inner command, the stub still exited 0, and the
    # control passed against the broken piped code — a fixture that looked like coverage and was
    # not. `exec` replaces the stub with the producer, so the producer's death IS the stub's.
    # Measured: `exit 0` form -> rc 0 (no bug visible), `exec` form -> rc 141 (bug visible).
    exec seq 1 20000
    ;;
"-S")
    echo '-P FORWARD ACCEPT'
    exit 0
    ;;
esac
exit 0
IPT
chmod +x "$IPJ/iptables"
ipj_enforced() {
    PITHEAD_ENGINE=docker JUMP="$1" PATH="$IPJ:$PATH" run_sourced "$EGV" tor_egress_enforced >/dev/null 2>&1
    echo $?
}
assert_eq "tagged rules + a live FORWARD jump -> ENFORCED" "$(ipj_enforced 1)" "0"
assert_eq "tagged rules in an ORPHANED chain -> NOT enforced (its own verdict, not 0)" "$(ipj_enforced 0)" "4"
ipj_out="$(PITHEAD_ENGINE=docker JUMP=0 RUNNING_CONTAINERS="tor" PATH="$IPJ:$PATH" run_sourced "$EGV" check_egress_firewall_installed 2>&1)"
assert_contains "doctor: orphaned DOCKER-USER -> FAIL naming the unconnected chain" "$ipj_out" "NOTHING JUMPS TO IT"
assert_not_contains "doctor: orphaned DOCKER-USER never reports fail-closed" "$ipj_out" "are fail-closed"
assert_contains "doctor: tagged rules + jump -> OK" \
    "$(PITHEAD_ENGINE=docker JUMP=1 RUNNING_CONTAINERS="tor" PATH="$IPJ:$PATH" run_sourced "$EGV" check_egress_firewall_installed 2>&1)" "fail-closed"
ipj_out="$(PITHEAD_ENGINE=docker JUMP=0 PATH="$IPJ:$PATH" run_sourced "$EGV" tor_egress_verify_or_warn "SHOULD-NOT-CLAIM" 2>&1)"
assert_not_contains "apply: a not-yet-jumped chain is not claimed as enforced" "$ipj_out" "SHOULD-NOT-CLAIM"
assert_not_contains "apply: ...and is not alarmed about either, on a first-ever up" "$ipj_out" "egress-apply:"
assert_contains "apply: it says what is actually true — staged, not yet traversed" "$ipj_out" "staged in DOCKER-USER"
unset IPJ ipj_out
unset -f ipj_enforced

echo "== 'enforced' must mean the DROP DECIDES, not that the word appears (#2059 final review) =="
DEC="$EGV/decide"
mkdir -p "$DEC"
cp "$EGV/bin/sudo" "$EGV/bin/docker" "$EGV/bin/systemctl" "$DEC/"

cat >"$DEC/nft" <<'NFT'
#!/usr/bin/env bash
case "$*" in
"list tables") echo "table inet pithead_egress" ;;
*"list table inet pithead_egress")
    if [ "${NFT_DECOY:-0}" = 1 ]; then
        cat <<'J'
{"nftables":[{"chain":{"name":"forward","hook":"forward","type":"filter"}},
{"chain":{"name":"decoy_unused"}},
{"rule":{"chain":"decoy_unused","expr":[{"drop":null}]}}]}
J
    else
        cat <<'J'
{"nftables":[{"chain":{"name":"forward","hook":"forward","type":"filter"}},
{"rule":{"chain":"forward","expr":[{"match":{"left":{"payload":{"protocol":"ip","field":"saddr"}},"op":"==","right":{"prefix":{"addr":"172.28.0.0","len":24}}}},{"drop":null}]}}]}
J
    fi
    ;;
esac
exit 0
NFT
chmod +x "$DEC/nft"
dec_rc() {
    local rc=0
    NFT_DECOY="$2" IPT_SHADOW="$3" PITHEAD_ENGINE="$1" PATH="$DEC:$PATH" \
        run_sourced "$EGV" tor_egress_enforced >/dev/null 2>&1 || rc=$?
    echo "$rc"
}
assert_eq "nft: drop INSIDE the hooked chain -> enforced" "$(dec_rc podman 0 0)" "0"
assert_eq "nft: hooked chain accepts, 'drop' only in an unhooked chain -> NOT enforced" "$(dec_rc podman 1 0)" "1"

cat >"$DEC/iptables" <<'IPT'
#!/usr/bin/env bash
case "$*" in
"-S DOCKER-USER")
    echo '-N DOCKER-USER'
    [ "${IPT_SHADOW:-0}" = 1 ] && echo '-A DOCKER-USER -s 172.28.0.0/24 -j ACCEPT'
    [ "${IPT_SHADOW:-0}" = 2 ] && echo '-A DOCKER-USER -j BYPASS'
    echo '-A DOCKER-USER -m comment --comment "pithead-tor-egress" -s 172.28.0.0/24 -j DROP'
    echo '-A DOCKER-USER -j RETURN'
    ;;
"-S FORWARD")
    [ "${IPT_FORWARD_SHADOW:-0}" = 1 ] && echo '-A FORWARD -s 172.28.0.0/24 -j ACCEPT'
    [ "${IPT_FORWARD_SHADOW:-0}" = 2 ] && echo '-A FORWARD ! -s 172.28.0.0/24 -j DOCKER-USER' || echo '-A FORWARD -j DOCKER-USER'
    ;;
"-S") echo '-P FORWARD ACCEPT' ;;
esac
exit 0
IPT
chmod +x "$DEC/iptables"
assert_eq "iptables: our DROP first, Docker's RETURN below it -> enforced" "$(dec_rc docker 0 0)" "0"
assert_eq "iptables: a foreign ACCEPT above our DROP -> NOT provably enforced" "$(dec_rc docker 0 1)" "5"
assert_eq "iptables: a user-chain jump above our DROP may accept -> NOT enforced" "$(dec_rc docker 0 2)" "5"
assert_eq "iptables: an ACCEPT before the FORWARD jump bypasses the DROP" "$(IPT_FORWARD_SHADOW=1 dec_rc docker 0 0)" "4"
assert_eq "iptables: a negated FORWARD jump excludes the mining subnet" "$(IPT_FORWARD_SHADOW=2 dec_rc docker 0 0)" "4"
dec_out="$(IPT_SHADOW=1 PITHEAD_ENGINE=docker PATH="$DEC:$PATH" run_sourced "$EGV" tor_egress_verify_or_warn "SHOULD-NOT-CLAIM" 2>&1)"
assert_not_contains "apply: a shadowed DROP is never claimed as enforced" "$dec_out" "SHOULD-NOT-CLAIM"
assert_contains "apply: ...and says which exit it took" "$dec_out" "egress-apply:shadowed"
dec_out="$(IPT_SHADOW=1 PITHEAD_ENGINE=docker RUNNING_CONTAINERS=tor PATH="$DEC:$PATH" run_sourced "$EGV" check_egress_firewall_installed 2>&1)"
assert_not_contains "doctor: a shadowed DROP is never reported fail-closed" "$dec_out" "are fail-closed"
assert_contains "doctor: ...and FAILs, because a WARN would still commit the A/B slot" "$dec_out" "sits ABOVE the DROP"
assert_contains "doctor: ...as a FAIL verdict, not a warning" "$dec_out" "FAIL"

cat >"$DEC/iptables-nojump" <<'IPT'
#!/usr/bin/env bash
case "$*" in
"-S DOCKER-USER")
    echo '-N DOCKER-USER'
    echo '-A DOCKER-USER -m comment --comment "pithead-tor-egress" -s 172.28.0.0/24 -j DROP'
    ;;
"-S FORWARD") echo '-P FORWARD ACCEPT' ;;
"-S") echo '-P FORWARD ACCEPT' ;;
esac
exit 0
IPT
cp "$DEC/iptables-nojump" "$DEC/iptables"
dec_out="$(PITHEAD_ENGINE=docker RUNNING_CONTAINERS='' PATH="$DEC:$PATH" run_sourced "$EGV" tor_egress_verify_or_warn "SHOULD-NOT-CLAIM" 2>&1)"
assert_contains "apply, stack NOT up: a missing jump is stated as staged, not alarmed" "$dec_out" "staged in DOCKER-USER"
dec_out="$(PITHEAD_ENGINE=docker RUNNING_CONTAINERS=tor PATH="$DEC:$PATH" run_sourced "$EGV" tor_egress_verify_or_warn "SHOULD-NOT-CLAIM" 2>&1)"
assert_contains "apply, only tor up: a missing jump is still staged, not alarmed" "$dec_out" "staged in DOCKER-USER"
assert_not_contains "apply, only tor up: ...and is not called a live fail-open" "$dec_out" "egress-apply:jump-missing"
unset -f dec_rc

echo "== the last three gaps the re-review found (#2059) =="
cat >"$DEC/nft-prec" <<'NFT'
#!/usr/bin/env bash
case "$*" in
*"list tables") echo "table inet pithead_egress" ;;
*"list table inet pithead_egress")
    printf '%s' '{"nftables":[{"chain":{"name":"forward","hook":"forward","type":"filter"}},'
    [ "${NFT_PRE_ACCEPT:-0}" = 1 ] && printf '%s' '{"rule":{"chain":"forward","expr":[{"accept":null}]}},'
    [ "${NFT_PRE_ACCEPT:-0}" = 2 ] && printf '%s' '{"rule":{"chain":"forward","expr":[{"counter":{"packets":0,"bytes":0}},{"accept":null}]}},'
    [ "${NFT_PRE_ACCEPT:-0}" = 3 ] && printf '%s' '{"rule":{"chain":"forward","expr":[{"match":{"left":{"payload":{"protocol":"ip","field":"saddr"}},"right":"172.28.0.25","op":"=="}},{"accept":null}]}},'
    [ "${NFT_PRE_ACCEPT:-0}" = 6 ] && printf '%s' '{"rule":{"chain":"forward","expr":[{"match":{"left":{"payload":{"protocol":"ip","field":"saddr"}},"right":{"prefix":{"addr":"172.28.0.0","len":24}},"op":"=="}},{"accept":null}]}},'
    [ "${NFT_PRE_ACCEPT:-0}" = 7 ] && printf '%s' '{"rule":{"chain":"forward","expr":[{"jump":{"target":"bypass"}}]}},'
    [ "${NFT_PRE_ACCEPT:-0}" = 8 ] && printf '%s' '{"rule":{"chain":"forward","expr":[{"return":null}]}},'
    sync_rule='{"rule":{"chain":"forward","expr":[{"match":{"left":{"payload":{"protocol":"ip","field":"saddr"}},"op":"==","right":"172.28.0.26"}},{"accept":null}]}}'
    [ "${NFT_PRE_ACCEPT:-0}" = 4 ] && printf '%s,' "$sync_rule"
    if [ "${NFT_PRE_ACCEPT:-0}" = 9 ]; then
        printf '%s' '{"rule":{"chain":"forward","expr":[{"match":{"left":{"payload":{"protocol":"ip","field":"saddr"}},"op":"==","right":{"prefix":{"addr":"192.0.2.0","len":24}}}},{"drop":null}]}}'
    else
        printf '%s' '{"rule":{"chain":"forward","expr":[{"match":{"left":{"payload":{"protocol":"ip","field":"saddr"}},"op":"==","right":{"prefix":{"addr":"172.28.0.0","len":24}}}},{"drop":null}]}}'
    fi
    [ "${NFT_PRE_ACCEPT:-0}" = 5 ] && printf ',%s' "$sync_rule"
    [ "${NFT_PRE_ACCEPT:-0}" = 7 ] && printf '%s' ',{"chain":{"name":"bypass"}},{"rule":{"chain":"bypass","expr":[{"accept":null}]}}'
    printf '%s\n' ']}' ;;
esac
exit 0
NFT
chmod +x "$DEC/nft-prec"
cp "$DEC/nft-prec" "$DEC/nft"
prec_rc() {
    local rc=0
    NFT_PRE_ACCEPT="$1" PITHEAD_ENGINE=podman PATH="$DEC:$PATH" run_sourced "$EGV" tor_egress_enforced >/dev/null 2>&1 || rc=$?
    echo "$rc"
}
assert_eq "nft: drop with only conditional rules above it -> enforced" "$(prec_rc 0)" "0"
assert_eq "nft: an UNCONDITIONAL accept above the drop -> NOT enforced" "$(prec_rc 1)" "1"
assert_eq "nft: counter+accept above the drop still shadows it -> NOT enforced" "$(prec_rc 2)" "1"
assert_eq "nft: the generated Tor-only accept is enforced" "$(prec_rc 3)" "0"
assert_eq "nft: a broad conditional subnet accept still leaks -> NOT enforced" "$(prec_rc 6)" "1"
assert_eq "nft: a jump to an accepting chain bypasses the DROP" "$(prec_rc 7)" "1"
assert_eq "nft: a base-chain RETURN bypasses the DROP" "$(prec_rc 8)" "1"
assert_eq "nft: a DROP for another subnet does not protect ours" "$(prec_rc 9)" "1"
cp "$EGV/.env" "$EGV/.env.before-nft-sync"
printf 'MONERO_CLEARNET_SYNC=true\n' >>"$EGV/.env"
assert_eq "nft: selected sync ACCEPT before DROP is enforced" "$(prec_rc 4)" "0"
assert_eq "nft: selected sync ACCEPT after DROP is ineffective" "$(prec_rc 5)" "1"
mv "$EGV/.env.before-nft-sync" "$EGV/.env"

cat >"$DEC/iptables" <<'IPT'
#!/usr/bin/env bash
case "$*" in
"-S DOCKER-USER")
    echo '-N DOCKER-USER'
    [ -n "${FOREIGN:-}" ] && echo "$FOREIGN"
    [ "${SYNC_ORDER:-}" = before ] && echo '-A DOCKER-USER -m comment --comment "pithead-tor-egress" -s 172.28.0.26 -j ACCEPT'
    echo '-A DOCKER-USER -m comment --comment "pithead-tor-egress" -s 172.28.0.0/24 -j DROP'
    [ "${SYNC_ORDER:-}" = after ] && echo '-A DOCKER-USER -m comment --comment "pithead-tor-egress" -s 172.28.0.26 -j ACCEPT'
    ;;
"-S FORWARD") echo '-A FORWARD -j DOCKER-USER' ;;
"-S") echo '-P FORWARD ACCEPT' ;;
esac
exit 0
IPT
chmod +x "$DEC/iptables"
fgn_rc() {
    local rc=0
    FOREIGN="$1" PITHEAD_ENGINE=docker PATH="$DEC:$PATH" run_sourced "$EGV" tor_egress_enforced >/dev/null 2>&1 || rc=$?
    echo "$rc"
}
assert_eq "iptables: a neighbour project's rule on another subnet -> still enforced" \
    "$(fgn_rc '-A DOCKER-USER -s 10.99.99.0/24 -d 10.99.99.1/32 -j ACCEPT')" "0"
assert_eq "iptables: an UNSCOPED accept above our DROP -> not provably enforced" \
    "$(fgn_rc '-A DOCKER-USER -j ACCEPT')" "5"
assert_eq "iptables: a broad ACCEPT with our tag is still unsafe" \
    "$(fgn_rc '-A DOCKER-USER -m comment --comment pithead-tor-egress -j ACCEPT')" "1"
assert_eq "iptables: a tagged RETURN cannot bypass our DROP" \
    "$(fgn_rc '-A DOCKER-USER -m comment --comment pithead-tor-egress -j RETURN')" "1"
assert_eq "iptables: an accept scoped to OUR subnet -> not provably enforced" \
    "$(fgn_rc '-A DOCKER-USER -s 172.28.0.0/24 -j ACCEPT')" "5"
assert_eq "iptables: a neighbour's non-terminating rule (LOG) -> still enforced" \
    "$(fgn_rc '-A DOCKER-USER -s 10.99.99.0/24 -j LOG')" "0"
assert_eq "iptables: a DISJOINT supernet -> still enforced" \
    "$(fgn_rc '-A DOCKER-USER -s 10.0.0.0/8 -j ACCEPT')" "0"
assert_eq "iptables: a SUPERNET containing our subnet -> not provably enforced" \
    "$(fgn_rc '-A DOCKER-USER -s 172.16.0.0/12 -j ACCEPT')" "5"
assert_eq "iptables: a NARROWER rule inside our subnet -> not provably enforced" \
    "$(fgn_rc '-A DOCKER-USER -s 172.28.0.128/25 -j ACCEPT')" "5"
assert_eq "iptables: a NEGATED accept scoped to exactly our subnet -> still enforced (excludes us)" \
    "$(fgn_rc '-A DOCKER-USER ! -s 172.28.0.0/24 -j ACCEPT')" "0"
assert_eq "iptables: a NEGATED accept on a DISJOINT subnet -> not provably enforced (matches us)" \
    "$(fgn_rc '-A DOCKER-USER ! -s 10.0.0.0/8 -j ACCEPT')" "5"
assert_eq "iptables: a NEGATED accept NARROWER than our subnet -> not provably enforced (exposes the rest)" \
    "$(fgn_rc '-A DOCKER-USER ! -s 172.28.0.0/25 -j ACCEPT')" "5"
assert_eq "iptables: a SECOND -m comment carrying the payload -> not provably enforced" \
    "$(fgn_rc '-A DOCKER-USER -m comment --comment "a" -m comment --comment "b ! -s 0.0.0.0/0 x" -s 172.28.0.0/24 -j ACCEPT')" "5"
assert_eq "iptables: a comment with an ESCAPED quote before the payload -> not provably enforced" \
    "$(fgn_rc '-A DOCKER-USER -m comment --comment "a\" ! -s 0.0.0.0/0 x" -s 172.28.0.0/24 -j ACCEPT')" "5"
assert_eq "iptables: the payload in -m string --string, which no comment strip ever covered -> not provably enforced" \
    "$(fgn_rc '-A DOCKER-USER -m string --string "! -s 0.0.0.0/0 x" --algo bm -s 172.28.0.0/24 -j ACCEPT')" "5"
assert_eq "iptables: a plain accept on our subnet with a comment embedding '! -s ' -> not provably enforced" \
    "$(fgn_rc '-A DOCKER-USER -m comment --comment "note ! -s 0.0.0.0/0 x" -s 172.28.0.0/24 -j ACCEPT')" "5"
assert_eq "iptables: an UNTERMINATED quote -> not provably enforced" \
    "$(fgn_rc '-A DOCKER-USER -m comment --comment "oops -s 1.2.3.4 -j ACCEPT')" "5"
assert_eq "iptables: a -s value that is not a CIDR -> not provably enforced" \
    "$(fgn_rc '-A DOCKER-USER -s 999.1.2.3/24 -j ACCEPT')" "5"
assert_eq "iptables: TWO -s on one rule (we cannot say which decides) -> not provably enforced" \
    "$(fgn_rc '-A DOCKER-USER -s 10.0.0.0/8 -s 172.28.0.0/24 -j ACCEPT')" "5"
cp "$EGV/.env" "$EGV/.env.before-sync"
printf 'MONERO_CLEARNET_SYNC=true\n' >>"$EGV/.env"
sync_order_rc() {
    local rc=0
    SYNC_ORDER="$1" PITHEAD_ENGINE=docker PATH="$DEC:$PATH" run_sourced "$EGV" tor_egress_enforced >/dev/null 2>&1 || rc=$?
    echo "$rc"
}
assert_eq "iptables: authorized first-sync ACCEPT before DROP is enforced" "$(sync_order_rc before)" "0"
assert_eq "iptables: authorized first-sync ACCEPT after DROP is ineffective" "$(sync_order_rc after)" "1"
mv "$EGV/.env.before-sync" "$EGV/.env"

cp "$DEC/iptables-nojump" "$DEC/iptables"
dec_out="$(RUNNING_CONTAINERS=p2pool PITHEAD_ENGINE=docker PATH="$DEC:$PATH" run_sourced "$EGV" tor_egress_verify_or_warn "SHOULD-NOT-CLAIM" 2>&1)"
assert_contains "apply: tor down but MINING up, jump missing -> a live fail-open, warned" "$dec_out" "egress-apply:jump-missing"
assert_not_contains "apply: ...not excused as first-boot staging" "$dec_out" "staged in DOCKER-USER"
unset -f prec_rc fgn_rc sync_order_rc
unset DEC dec_out
