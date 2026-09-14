# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Tor-egress ENFORCEMENT domain (#2059): does the product's stated security property hold at the one
# place a shell can check it — the rules the kernel is actually holding?
#
# Split out of test-tor-network.sh (which owns the RENDERER and the transport switch) because these
# assert a different thing about the same subsystem: not "is the right ruleset produced" but "did
# anything confirm it landed, and does the machine say so when it did not". A fail-open appliance
# shipped green through every battery to date precisely because nothing asked the second question —
# apply logged "Tor-only egress enforced" off a zero exit from the install command, and doctor's
# can't-check paths all degraded to info, so a box with no firewall exited 0 into the A/B commit
# gate that os/overlay/pithead-boot uses to decide whether a slot is healthy enough to keep.
#
# Both halves now read the live state through one tor_egress_enforced(), so they belong in one
# domain rather than on either side of an apply/doctor line they no longer sit across. Self-
# contained stubs on purpose: a fragment that borrowed the neighbouring domain's $NFW/$DRBIN would
# pass or fail on the order run.sh happens to source files in.
# Sourced by tests/stack/run.sh.

# A PATH with every *sbin* directory removed, so a test can drive the "privileged tool is not
# installed" branch without uninstalling anything. nft and iptables both live in /usr/sbin; grep,
# tr and printf — which sourcing pithead needs — do not, so what remains is still a working shell
# environment. Callers pair this with an assertion that the tool really did disappear: a helper
# that silently stopped working would otherwise turn a branch test into a tautology.
path_without_sbin() {
    local d out="" IFS=:
    for d in $PATH; do
        case "$d" in *sbin*) ;; *) out="${out:+$out:}$d" ;; esac
    done
    printf '%s' "$out"
}

EGV="$SANDBOX/egress-enforcement"
mkdir -p "$EGV/bin" "$EGV/bin-nonft"
# sudo that strips its OWN flags. The `exec "$@"` stub the renderer domain uses would try to exec
# `-n`, which makes every readback read as "unreadable" and hides the branches under test here.
cat >"$EGV/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -n | -H | -E) shift ;; *) break ;; esac; done
exec "$@"
SUDO
# nft: `-f` always loads. The readback reports the table only when NFT_LIVE=1, so "the install
# command exited zero" and "the rules are live" can disagree — the appliance's measured state.
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
    printf '%s\n' '{"nftables":[{"chain":{"name":"forward","hook":"forward","type":"filter"}},{"rule":{"chain":"forward","expr":[{"drop":null}]}}]}'
    exit 0
    ;;
esac
exit 0
NFT
# container_is_running shells out to `docker` whatever the engine is (podman-docker on the
# appliance), so the doctor rows below need it to answer for the tor container.
cat >"$EGV/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
name=$(printf '%s' "$*" | sed -n 's/.*name=\^\([a-z0-9-]*\)\$.*/\1/p')
case " ${RUNNING_CONTAINERS:-} " in *" $name "*) echo cid123 ;; esac
exit 0
DOCKER
chmod +x "$EGV/bin/sudo" "$EGV/bin/nft" "$EGV/bin/docker"
cp "$EGV/bin/sudo" "$EGV/bin/docker" "$EGV/bin-nonft/"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$EGV/.env"

echo "== the #858 refusal must survive errexit, the way production runs it (#2059) =="
# tests/stack/lib.sh's run_sourced does `set +e` before calling — precisely the condition production
# does NOT have. pithead runs under `set -Eeuo pipefail`, where `br=$(mining_net_ipv6_bridge)` with a
# non-zero return is a FAILING SIMPLE COMMAND: errexit fires and the shell is gone before the next
# line can read $?. So the #858 refusal was green in the renderer domain and DEAD in the product — a
# v6-capable mining_net killed `up` mid-stack_up with rc 3 and no message at all. Driving it with
# errexit ON is the only way an assertion about that branch means anything.
printf '#!/usr/bin/env bash\necho '"'"'[{"name":"mining_net","subnets":[{"subnet":"fd00:dead:beef::/64"}]}]'"'"'\n' >"$EGV/bin/podman"
chmod +x "$EGV/bin/podman"
: >"$EGV/nft.ruleset"
ee_out="$(cd "$EGV" && PITHEAD_ENGINE=podman PATH="$EGV/bin:$PATH" NFT_RULESET="$EGV/nft.ruleset" bash -c "source '$STACK'; apply_tor_egress_firewall" 2>&1)"
assert_rc "the refusal returns cleanly under errexit (it no longer dies at the assignment)" "$?" "0"
assert_contains "the refusal under errexit still reaches its REFUSING warning" "$ee_out" "REFUSING"
assert_eq "the refusal under errexit loads no ruleset (no half-open v4-only firewall)" "$(cat "$EGV/nft.ruleset")" ""
rm -f "$EGV/bin/podman"

echo "== apply only CLAIMS enforcement after reading the rules back (#2059) =="
# The load succeeds and the live table is absent — the disagreement measured on the appliance. The
# old code logged "Tor-only egress enforced" here, which is the line the whole defect hid behind.
egv_out="$(PITHEAD_ENGINE=podman NFT_LIVE=0 PATH="$EGV/bin:$PATH" run_sourced "$EGV" apply_tor_egress_firewall 2>&1)"
assert_not_contains "a load that did not land never claims 'Tor-only egress enforced'" "$egv_out" "Tor-only egress enforced"
assert_contains "...and names which exit it took, for the bounded journal excerpt" "$egv_out" "egress-apply:verify-absent"
# Same code, table live: the claim is earned, and no failure token rides along with it.
egv_out="$(PITHEAD_ENGINE=podman NFT_LIVE=1 PATH="$EGV/bin:$PATH" run_sourced "$EGV" apply_tor_egress_firewall 2>&1)"
assert_contains "a verified install DOES claim enforcement" "$egv_out" "Tor-only egress enforced"
assert_not_contains "...and carries no egress-apply failure token" "$egv_out" "egress-apply:"

echo "== a missing backend tool is NAMED by apply and FAILED by doctor (#2059) =="
# nft lives in /usr/sbin, so dropping the sbin dirs removes the real one; $EGV/bin-nonft carries the
# rest of the stubs without the nft stub. The precondition is asserted rather than assumed — a
# helper that silently stopped working would turn both rows below into tautologies.
assert_eq "harness: nft really is absent from the no-nft PATH" \
    "$(PATH="$EGV/bin-nonft:$(path_without_sbin)" command -v nft 2>/dev/null || echo absent)" "absent"
notool_out="$(PITHEAD_ENGINE=podman PATH="$EGV/bin-nonft:$(path_without_sbin)" run_sourced "$EGV" apply_tor_egress_firewall 2>&1)"
assert_contains "no nft on PATH -> apply names that exit" "$notool_out" "egress-apply:nft-missing"
assert_not_contains "no nft on PATH -> apply never claims enforcement" "$notool_out" "Tor-only egress enforced"
# And the doctor half: engine podman with no nft binary means the firewall CANNOT be enforced, so
# nothing is dropping. That used to take the same info-skip door as a sudo refusal — which is how a
# leaking slot exited 0 and marked itself good. A missing tool is a CONFIRMED absence, not an
# unknown; only a sudo refusal is an honest "I cannot tell", and that one still skips.
notool_out="$(PITHEAD_ENGINE=podman RUNNING_CONTAINERS="tor" PATH="$EGV/bin-nonft:$(path_without_sbin)" run_sourced "$EGV" check_egress_firewall_installed 2>&1)"
assert_contains "doctor (podman): no nft binary -> FAIL, not a skip" "$notool_out" "CANNOT be enforced"
assert_not_contains "doctor (podman): a missing tool is not reported as a sudo problem" "$notool_out" "passwordless sudo"

echo "== the iptables backend proves REACHABILITY, not just presence (#855 inside the verifier) =="
# An adversarial review of #2091 caught this: asserting the tagged rules are IN DOCKER-USER proves
# only that WE wrote them there — apply_tor_egress_iptables pre-creates the chain itself. #855's
# actual failure is a DROP in a chain nothing traverses, which a presence-only check cannot see. The
# nft branch proves reachability via the forward hook; the iptables equivalent is the FORWARD jump.
#
# Absence of the jump means OPPOSITE things at the two call sites, so it has its own rc: at APPLY
# time the rules deliberately go in before compose (Docker adds the jump with its first network), so
# alarming would cry wolf on every fresh install; at DOCTOR time the stack is up and a missing jump
# is a live fail-open.
IPJ="$EGV/ipj"
mkdir -p "$IPJ"
cp "$EGV/bin/sudo" "$EGV/bin/docker" "$IPJ/"
# iptables: DOCKER-USER always carries our tagged rules; the FORWARD jump exists only when JUMP=1.
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
ipj_enforced() { # <JUMP> -> rc of tor_egress_enforced on the Docker branch
    PITHEAD_ENGINE=docker JUMP="$1" PATH="$IPJ:$PATH" run_sourced "$EGV" tor_egress_enforced >/dev/null 2>&1
    echo $?
}
assert_eq "tagged rules + a live FORWARD jump -> ENFORCED" "$(ipj_enforced 1)" "0"
assert_eq "tagged rules in an ORPHANED chain -> NOT enforced (its own verdict, not 0)" "$(ipj_enforced 0)" "4"
# doctor sees a live stack, so a missing jump there is a fail-open and must FAIL — never dr_ok.
ipj_out="$(PITHEAD_ENGINE=docker JUMP=0 RUNNING_CONTAINERS="tor" PATH="$IPJ:$PATH" run_sourced "$EGV" check_egress_firewall_installed 2>&1)"
assert_contains "doctor: orphaned DOCKER-USER -> FAIL naming the unconnected chain" "$ipj_out" "NOTHING JUMPS TO IT"
assert_not_contains "doctor: orphaned DOCKER-USER never reports fail-closed" "$ipj_out" "are fail-closed"
# ...and with the jump present it is the ordinary OK, so the row above is not just "doctor always fails".
assert_contains "doctor: tagged rules + jump -> OK" \
    "$(PITHEAD_ENGINE=docker JUMP=1 RUNNING_CONTAINERS="tor" PATH="$IPJ:$PATH" run_sourced "$EGV" check_egress_firewall_installed 2>&1)" "fail-closed"
# apply must NOT cry wolf before compose has created the network — the jump is legitimately absent
# there, and apply_tor_egress_iptables' own comment says Docker adds it afterwards.
ipj_out="$(PITHEAD_ENGINE=docker JUMP=0 PATH="$IPJ:$PATH" run_sourced "$EGV" tor_egress_verify_or_warn "SHOULD-NOT-CLAIM" 2>&1)"
assert_not_contains "apply: a not-yet-jumped chain is not claimed as enforced" "$ipj_out" "SHOULD-NOT-CLAIM"
assert_not_contains "apply: ...and is not alarmed about either, on a first-ever up" "$ipj_out" "egress-apply:"
assert_contains "apply: it says what is actually true — staged, not yet traversed" "$ipj_out" "staged in DOCKER-USER"
unset IPJ ipj_out
unset -f ipj_enforced

echo "== 'enforced' must mean the DROP DECIDES, not that the word appears (#2059 final review) =="
# A pre-merge adversarial review executed the real tor_egress_enforced() against two realistic
# kernel states and got rc 0 — "enforced" — on both while clearnet egress was open. Presence is not
# enforcement, and these are the two ways that came apart.
DEC="$EGV/decide"
mkdir -p "$DEC"
cp "$EGV/bin/sudo" "$EGV/bin/docker" "$DEC/"

# (1) nft: the hooked chain only ACCEPTS; a second, unhooked chain merely CONTAINS the word "drop".
# Two independent greps over one dump are both satisfied; the kernel drops nothing.
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
{"rule":{"chain":"forward","expr":[{"drop":null}]}}]}
J
    fi
    ;;
esac
exit 0
NFT
chmod +x "$DEC/nft"
# `env` cannot invoke a SHELL FUNCTION, and run_sourced is one — the first cut of this helper
# silently failed every call rather than exercising the branch. Prefix assignments are what the
# rest of this file uses, and they demonstrably reach the stub processes.
dec_rc() { # <engine> <NFT_DECOY> <IPT_SHADOW> -> rc of the real tor_egress_enforced
    local rc=0
    NFT_DECOY="$2" IPT_SHADOW="$3" PITHEAD_ENGINE="$1" PATH="$DEC:$PATH" \
        run_sourced "$EGV" tor_egress_enforced >/dev/null 2>&1 || rc=$?
    echo "$rc"
}
assert_eq "nft: drop INSIDE the hooked chain -> enforced" "$(dec_rc podman 0 0)" "0"
assert_eq "nft: hooked chain accepts, 'drop' only in an unhooked chain -> NOT enforced" "$(dec_rc podman 1 0)" "1"

# (2) iptables: our tagged DROP is present and the chain IS jumped to, but a foreign ACCEPT sits
# above it. iptables is first-match-wins (inserting an ACCEPT at DOCKER-USER position 1 is a
# documented ufw/firewalld workaround), so the DROP never fires.
cat >"$DEC/iptables" <<'IPT'
#!/usr/bin/env bash
case "$*" in
"-S DOCKER-USER")
    echo '-N DOCKER-USER'
    [ "${IPT_SHADOW:-0}" = 1 ] && echo '-A DOCKER-USER -s 172.28.0.0/24 -j ACCEPT'
    echo '-A DOCKER-USER -m comment --comment "pithead-tor-egress" -s 172.28.0.0/24 -j DROP'
    echo '-A DOCKER-USER -j RETURN'
    ;;
"-S FORWARD") echo '-A FORWARD -j DOCKER-USER' ;;
"-S") echo '-P FORWARD ACCEPT' ;;
esac
exit 0
IPT
chmod +x "$DEC/iptables"
assert_eq "iptables: our DROP first, Docker's RETURN below it -> enforced" "$(dec_rc docker 0 0)" "0"
assert_eq "iptables: a foreign ACCEPT above our DROP -> NOT provably enforced" "$(dec_rc docker 0 1)" "5"
# ...and neither apply nor doctor may call that "enforced".
dec_out="$(IPT_SHADOW=1 PITHEAD_ENGINE=docker PATH="$DEC:$PATH" run_sourced "$EGV" tor_egress_verify_or_warn "SHOULD-NOT-CLAIM" 2>&1)"
assert_not_contains "apply: a shadowed DROP is never claimed as enforced" "$dec_out" "SHOULD-NOT-CLAIM"
assert_contains "apply: ...and says which exit it took" "$dec_out" "egress-apply:shadowed"
dec_out="$(IPT_SHADOW=1 PITHEAD_ENGINE=docker RUNNING_CONTAINERS=tor PATH="$DEC:$PATH" run_sourced "$EGV" check_egress_firewall_installed 2>&1)"
assert_not_contains "doctor: a shadowed DROP is never reported fail-closed" "$dec_out" "are fail-closed"
assert_contains "doctor: ...and FAILs, because a WARN would still commit the A/B slot" "$dec_out" "sits ABOVE the DROP"
assert_contains "doctor: ...as a FAIL verdict, not a warning" "$dec_out" "FAIL"

# (3) A missing FORWARD jump is benign ONLY before the stack exists. With the stack up it is a live
# fail-open, and apply must say so rather than inherit stack_up's first-boot framing.
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
# tor alone is NOT a live mining stack: nothing clearnet-capable is running, so a missing jump has
# nothing to leak and the first-boot framing is honest. The signal is mining_stack_running, and this
# row is what stops it drifting back to tor's own liveness (which reported a MINING-up, tor-down box
# as benign — the re-review found that by execution).
dec_out="$(PITHEAD_ENGINE=docker RUNNING_CONTAINERS=tor PATH="$DEC:$PATH" run_sourced "$EGV" tor_egress_verify_or_warn "SHOULD-NOT-CLAIM" 2>&1)"
assert_contains "apply, only tor up: a missing jump is still staged, not alarmed" "$dec_out" "staged in DOCKER-USER"
assert_not_contains "apply, only tor up: ...and is not called a live fail-open" "$dec_out" "egress-apply:jump-missing"
unset -f dec_rc

echo "== the last three gaps the re-review found (#2059) =="
# (a) A drop BELOW an unconditional accept in the same hooked chain never fires. Verified against
# real nftables: that shape read as "enforced" until the check learned rule ORDER.
cat >"$DEC/nft-prec" <<'NFT'
#!/usr/bin/env bash
case "$*" in
*"list tables") echo "table inet pithead_egress" ;;
*"list table inet pithead_egress")
    printf '%s' '{"nftables":[{"chain":{"name":"forward","hook":"forward","type":"filter"}},'
    [ "${NFT_PRE_ACCEPT:-0}" = 1 ] && printf '%s' '{"rule":{"chain":"forward","expr":[{"accept":null}]}},'
    [ "${NFT_PRE_ACCEPT:-0}" = 2 ] && printf '%s' '{"rule":{"chain":"forward","expr":[{"counter":{"packets":0,"bytes":0}},{"accept":null}]}},'
    [ "${NFT_PRE_ACCEPT:-0}" = 3 ] && printf '%s' '{"rule":{"chain":"forward","expr":[{"match":{"left":{"payload":{"protocol":"ip","field":"daddr"}},"right":"192.0.2.1","op":"=="}},{"accept":null}]}},'
    printf '%s\n' '{"rule":{"chain":"forward","expr":[{"drop":null}]}}]}' ;;
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
# A security review found the first cut of this check matched the accept rule's expr array
# byte-for-byte, so `counter accept` and `log accept` — the standard idioms for a visible/audited
# allow-all — read as "conditional" and the shadowing drop below them was called "enforced".
assert_eq "nft: counter+accept above the drop still shadows it -> NOT enforced" "$(prec_rc 2)" "1"
assert_eq "nft: a genuinely scoped match+accept does not shadow -> enforced" "$(prec_rc 3)" "0"

# (b) DOCKER-USER is host-wide and shared with every other compose project. A neighbour's rule that
# cannot match the mining subnet must NOT be called shadowing, or the verdict fires forever on
# healthy hosts and stops meaning anything.
cat >"$DEC/iptables" <<'IPT'
#!/usr/bin/env bash
case "$*" in
"-S DOCKER-USER")
    echo '-N DOCKER-USER'
    [ -n "${FOREIGN:-}" ] && echo "$FOREIGN"
    echo '-A DOCKER-USER -m comment --comment "pithead-tor-egress" -s 172.28.0.0/24 -j DROP'
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
assert_eq "iptables: an accept scoped to OUR subnet -> not provably enforced" \
    "$(fgn_rc '-A DOCKER-USER -s 172.28.0.0/24 -j ACCEPT')" "5"
assert_eq "iptables: a neighbour's non-terminating rule (LOG) -> still enforced" \
    "$(fgn_rc '-A DOCKER-USER -s 10.99.99.0/24 -j LOG')" "0"
# #2117: CIDR-containment math, not a literal `-s` string match. A disjoint supernet is the
# negative control — the fix must not degrade into "any foreign rule shadows".
assert_eq "iptables: a DISJOINT supernet -> still enforced" \
    "$(fgn_rc '-A DOCKER-USER -s 10.0.0.0/8 -j ACCEPT')" "0"
assert_eq "iptables: a SUPERNET containing our subnet -> not provably enforced" \
    "$(fgn_rc '-A DOCKER-USER -s 172.16.0.0/12 -j ACCEPT')" "5"
assert_eq "iptables: a NARROWER rule inside our subnet -> not provably enforced" \
    "$(fgn_rc '-A DOCKER-USER -s 172.28.0.128/25 -j ACCEPT')" "5"
# A NEGATED `! -s` accept matches everything OUTSIDE the given block — the opposite of a plain
# match. A disjoint `! -s` is the dangerous case: negation makes it match exactly our subnet.
assert_eq "iptables: a NEGATED accept scoped to exactly our subnet -> still enforced (excludes us)" \
    "$(fgn_rc '-A DOCKER-USER ! -s 172.28.0.0/24 -j ACCEPT')" "0"
assert_eq "iptables: a NEGATED accept on a DISJOINT subnet -> not provably enforced (matches us)" \
    "$(fgn_rc '-A DOCKER-USER ! -s 10.0.0.0/8 -j ACCEPT')" "5"

# (c) Tor can be DOWN while the mining containers keep running — a live, clearnet-capable stack.
# Keying the "is this benign?" question on tor alone reported that as the first-boot case.
cp "$DEC/iptables-nojump" "$DEC/iptables"
dec_out="$(RUNNING_CONTAINERS=p2pool PITHEAD_ENGINE=docker PATH="$DEC:$PATH" run_sourced "$EGV" tor_egress_verify_or_warn "SHOULD-NOT-CLAIM" 2>&1)"
assert_contains "apply: tor down but MINING up, jump missing -> a live fail-open, warned" "$dec_out" "egress-apply:jump-missing"
assert_not_contains "apply: ...not excused as first-boot staging" "$dec_out" "staged in DOCKER-USER"
unset -f prec_rc fgn_rc
unset DEC dec_out
