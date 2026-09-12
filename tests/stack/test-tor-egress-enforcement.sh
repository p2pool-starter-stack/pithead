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
"list table inet pithead_egress")
    [ "${NFT_LIVE:-0}" = 1 ] || exit 1
    printf '%s\n' 'table inet pithead_egress {' '  chain forward {' \
        '    type filter hook forward priority -5; policy accept;' \
        '    ip saddr 172.28.0.0/24 drop' '  }' '}'
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
