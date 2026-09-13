# --- Tor-only egress enforcement (#270) ---------------------------------------------------------
# Fail-closed host firewall so a misconfigured/buggy bridge daemon (monerod/p2pool/tari/xmrig-proxy)
# CAN'T leak the home IP: each may reach the LAN, the other containers and the Tor SOCKS, but any
# DIRECT clearnet dial is DROPPED — only the `tor` container reaches the internet. Rules live in
# Docker's DOCKER-USER chain (preserved across Docker restarts), installed BEFORE containers start on
# every path that brings a clearnet-capable app up — `up`, `upgrade`, `apply`, `reset-dashboard` (so
# there is no startup window to grandfather a leak past) — and removed at `down`. Needs
# root (sudo), like the GRUB/HugePages steps. The allow-set is IPv4 (mining_net is IPv4-only by
# design); the nft backend also fences IPv6 off the mining bridge if mining_net ever gains a v6
# subnet, so the backstop can't silently fail open. Opt out with
# network.tor_egress_firewall=false. Proven by tests/integration/benchmarks/bench-verify-egress.sh.
# See docs/privacy.md.
#
# Two enforcement backends, one allow-set. Docker adds a `FORWARD -> DOCKER-USER` jump when it
# creates a network, so on the DIY/Docker channel the rules live in DOCKER-USER (iptables). The
# appliance runs podman + netavark, which never adds that jump — DOCKER-USER is orphaned there and
# the DROP never fires. On the podman path we instead install an independent `inet pithead_egress`
# nftables table hooked at forward priority -5 (ahead of netavark's priority-0 accept), owning no
# chain shared with netavark so it survives netavark reprogramming its own table. apply/remove/doctor
# all branch on container_engine.
TOR_EGRESS_TAG="pithead-tor-egress"
TOR_EGRESS_NFT_TABLE="pithead_egress"

# Ordered iptables rule bodies (no chain/comment) for <subnet> <tor_ip>. Pure (args only) so it
# unit-tests; ACCEPTs first, DROP last — the order is load-bearing.
tor_egress_rules() { # <subnet> <tor_ip>
    local subnet="$1" tor_ip="$2"
    printf '%s\n' \
        "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" \
        "-s $tor_ip -j ACCEPT" \
        "-s $subnet -d 10.0.0.0/8 -j ACCEPT" \
        "-s $subnet -d 172.16.0.0/12 -j ACCEPT" \
        "-s $subnet -d 192.168.0.0/16 -j ACCEPT" \
        "-s $subnet -d 100.64.0.0/10 -j ACCEPT" \
        "-s $subnet -j DROP"
}

# Full `nft -f` ruleset for the appliance/netavark path — same allow-set as tor_egress_rules, in
# native nftables. Pure (args only) so it unit-tests. `add`+`delete` before the table body is the
# canonical atomic idempotent-replace: `add table` no-ops if it already exists, `delete` then clears
# it, and the block recreates it fresh — the whole file loads as one transaction. The base chain is
# hooked at forward priority -5 so it evaluates before netavark's priority-0 blanket accept; a `drop`
# there is terminal across the ruleset. accepts come first so LAN/Tor/established traffic skips the
# final subnet-wide drop, mirroring the iptables order.
#
# The optional third arg is the mining bridge interface. mining_net is IPv4-only by design, so it is
# empty on every normal apply and the ruleset stays v4-only. If mining_net ever gains an IPv6 subnet
# the caller resolves the bridge and passes it here, which appends the v6 fail-closed backstop: there
# is no assigned v6 range to source-match, so the drop is keyed on the mining bridge INTERFACE — the
# host's own IPv6 forwarding on every other interface is left untouched.
render_tor_egress_nft() { # <subnet> <tor_ip> [<mining_bridge>]
    local subnet="$1" tor_ip="$2" br="${3:-}"
    printf '%s\n' \
        "add table inet $TOR_EGRESS_NFT_TABLE" \
        "delete table inet $TOR_EGRESS_NFT_TABLE" \
        "table inet $TOR_EGRESS_NFT_TABLE {" \
        "  chain forward {" \
        "    type filter hook forward priority -5; policy accept;" \
        "    ct state established,related accept" \
        "    ip saddr $tor_ip accept" \
        "    ip saddr $subnet ip daddr 10.0.0.0/8 accept" \
        "    ip saddr $subnet ip daddr 172.16.0.0/12 accept" \
        "    ip saddr $subnet ip daddr 192.168.0.0/16 accept" \
        "    ip saddr $subnet ip daddr 100.64.0.0/10 accept" \
        "    ip saddr $subnet drop"
    # IPv6 backstop, only when mining_net actually has v6 (br set). ct established,related above is
    # family-agnostic and already spares return traffic; here we allow the v6 LAN (ULA fc00::/7 +
    # link-local fe80::/10) off the mining bridge and drop everything else it originates. Scoped to
    # iifname so it can never touch v6 forwarded from any other interface.
    if [ -n "$br" ]; then
        printf '%s\n' \
            "    iifname \"$br\" ip6 daddr fc00::/7 accept" \
            "    iifname \"$br\" ip6 daddr fe80::/10 accept" \
            "    iifname \"$br\" meta nfproto ipv6 drop"
    fi
    printf '%s\n' \
        "  }" \
        "}"
}

# Resolve the mining bridge interface IFF mining_net carries an IPv6 subnet — both come from the same
# `podman network inspect`, so whenever v6 is present the interface name is too. Prints the bridge
# name for the v6 backstop; prints nothing when mining_net is IPv4-only (the normal case) or absent
# (a first-ever `up`, where the firewall installs before compose creates the network). Sole tricky
# case — a v6 subnet present but no resolvable interface — is signalled by rc 3 so the caller can
# refuse rather than install a v4-only firewall it would wrongly call fail-closed.
mining_net_ipv6_bridge() {
    local inspect v6 br
    inspect=$(podman network inspect mining_net 2>/dev/null) || return 0
    v6=$(printf '%s' "$inspect" | jq -r '[.[0].subnets[]?.subnet | select(test(":"))][0] // empty' 2>/dev/null)
    [ -n "$v6" ] || return 0
    br=$(printf '%s' "$inspect" | jq -r '.[0].network_interface // empty' 2>/dev/null)
    [ -n "$br" ] || return 3
    printf '%s' "$br"
}

# Read the LIVE enforcement state back out of the kernel. Single-sourced on purpose (#2059): it is
# what `apply` proves its own install with AND what `doctor` reports, so the two can no longer
# disagree about what "installed" means. Before this, apply logged "Tor-only egress enforced"
# straight off a zero exit from the install command and doctor kept a second, differently-shaped
# copy of the probe — an appliance that installed nothing shipped green behind both.
#
# The hook, not merely a rule: the failure #855 was about is a DROP sitting in a chain no packet
# traverses, which is exactly what a base chain hooked at forward CANNOT be.
#
# rc 0 = enforced. 1 = definitively NOT enforced (we read the ruleset; the rules are not in it).
# 2 = CANNOT be enforced at all (the backend's tool is absent — not an unknown, a certainty that
# nothing is dropping). 3 = genuinely unreadable (no passwordless sudo), the only verdict that is
# an honest "I cannot tell". 4 = the rules are installed but NOTHING TRAVERSES THEM — see the
# iptables branch. 5 = installed and reachable, but a FOREIGN rule sits ABOVE our DROP, so we
# cannot claim the drop is what decides — not proof of a leak, proof we cannot verify one is absent.
# Callers act on all six differently; collapsing 2 into 3 is how a fail-open box passed the A/B
# commit gate, and collapsing 4 or 5 into 0 would hide #855's own failure mode inside the verifier
# written to close it.
tor_egress_enforced() {
    local out
    if [ "$(container_engine)" = "podman" ]; then
        command -v nft >/dev/null 2>&1 || return 2
        # `nft list table` returns rc 1 both when the table is missing AND when sudo -n is refused; a
        # cheap `list tables` probe (succeeds whether or not our table exists) tells the two apart, so
        # a sudo refusal can't masquerade as a missing firewall (a false "not enforced").
        command -v jq >/dev/null 2>&1 || return 3
        sudo -n nft list tables >/dev/null 2>&1 || return 3
        out=$(sudo -n nft -j list table inet "$TOR_EGRESS_NFT_TABLE" 2>/dev/null) || return 1
        # STRUCTURE, not two greps over one dump. The first cut asked `grep -q 'hook forward'` and
        # `grep -qw drop` INDEPENDENTLY — which a table satisfies when its hooked chain only ACCEPTS
        # and some OTHER chain merely contains the word "drop". Measured rc 0 on exactly that state:
        # "enforced" while forward traffic was wide open. The drop has to be IN a chain hooked at
        # forward, and only the JSON can say so. `nft -j` and jq are already dependencies of this
        # file — mining_net_ipv6_bridge parses podman's JSON with jq a few lines below.
        #
        # Here-string, not a pipe: under `pipefail` a consumer that exits early makes the producer
        # take SIGPIPE and the pipeline yield 141, firing the guard on a SUCCESSFUL match. That
        # shipped once and real hardware caught it.
        # ...and PRECEDENCE within it, for the same reason the iptables branch walks rule order: a
        # drop below an unconditional `accept` in the same hooked chain never fires. Verified
        # against real nftables — that shape read as "enforced" before this clause.
        #
        # UNCONDITIONAL means "no `match` statement ahead of the verdict", not "the rule is a bare
        # `{accept}` and nothing else". `counter accept` and `log accept` are the standard nftables
        # idioms for a visible/audited allow-all, and both shadow the drop exactly like a bare
        # accept does — a security review caught that the byte-exact check missed them (false
        # "enforced"). Every real packet-filter condition (address, port, protocol, ct state) is
        # represented under the `match` key in `nft -j` output; `counter`/`log`/`limit`/`quota` and
        # anything else are side-effect statements that never narrow which packets they apply to,
        # so their presence ahead of `accept` still makes the rule unconditional.
        jq -e '
            def is_unconditional_accept:
                (length > 0) and (.[-1] == {"accept":null}) and (.[0:-1] | all(has("match") | not));
            [.nftables[] | select(has("chain")) | select(.chain.hook == "forward") | .chain.name] as $h
            | [.nftables[] | select(has("rule")) | select(.rule.chain as $c | $h | index($c)) | .rule.expr] as $r
            | ($r | map(any(has("drop"))) | index(true)) as $d
            | $d != null and (($r[0:$d] // []) | all(is_unconditional_accept | not))
        ' >/dev/null 2>&1 <<<"$out" || return 1
        return 0
    fi
    command -v iptables >/dev/null 2>&1 || return 2
    # Same two-probe shape as the nft branch above, and for the same reason: `-S DOCKER-USER` fails
    # both when sudo is refused AND when the chain does not exist. A bare `-S` (which lists whatever
    # is there) separates them, so a deleted DOCKER-USER reads as NOT ENFORCED rather than as an
    # unreadable ruleset doctor would skip past.
    sudo -n iptables -S >/dev/null 2>&1 || return 3
    out=$(sudo -n iptables -S DOCKER-USER 2>/dev/null) || return 1
    grep -qE -- "$TOR_EGRESS_TAG.* -j DROP" <<<"$out" || return 1
    # iptables is FIRST MATCH WINS, so a rule ABOVE our DROP makes it dead while it is still
    # "present". Inserting an ACCEPT at DOCKER-USER position 1 is a documented ufw/firewalld
    # workaround, and this function measured rc 0 — "enforced" — with the DROP unreachable behind
    # one. We install positions 1..7 with the DROP last, so anything untagged above it is foreign
    # and we cannot claim our drop decides. `-N`/`-P` are chain declarations, not rules; Docker's
    # own `-j RETURN` sits BELOW our inserts, so this loop breaks before ever reaching it.
    local line subnet
    subnet=$(env_get NETWORK_SUBNET 2>/dev/null)
    [ -n "$subnet" ] || subnet="172.28.0.0/24"
    while IFS= read -r line; do
        case "$line" in
        -N* | -P*) continue ;;
        *"$TOR_EGRESS_TAG"*" -j DROP"*) break ;;
        *"$TOR_EGRESS_TAG"*) continue ;;
        *)
            # A foreign rule only shadows if it TERMINATES the chain (ACCEPT/RETURN) *and* could
            # match our traffic — unscoped, or scoped to our own subnet. DOCKER-USER is host-wide
            # and shared with every other compose project (ufw-docker writes there), so flagging a
            # rule that cannot match us would fire permanently on healthy hosts and desensitise the
            # one time it matters. KNOWN GAP, stated rather than hidden: a `-s` SUPERNET containing
            # our subnet is not recognised as overlapping, so it reads as harmless.
            case "$line" in
            *" -j ACCEPT" | *" -j RETURN" | *" -j ACCEPT "* | *" -j RETURN "*) ;;
            *) continue ;;
            esac
            case "$line" in
            *" -s "*)
                # -F: $subnet is operator data (NETWORK_SUBNET), matched literally — a glob
                # metacharacter in it must not change what this matches.
                grep -qF -- " -s $subnet " <<<"$line " && return 5
                continue
                ;;
            *) return 5 ;;
            esac
            ;;
        esac
    done <<<"$out"
    # REACHABILITY AND PRECEDENCE, not just presence. #855 was a DROP in a chain no packet traverses, and
    # asserting the tagged rules exist cannot see that — `apply_tor_egress_iptables` pre-creates
    # DOCKER-USER itself, so a populated chain proves only that WE wrote to it. The nft branch above
    # proves reachability by asserting the base chain's forward hook; the iptables equivalent is the
    # FORWARD -> DOCKER-USER jump, which Docker adds when it creates a network.
    #
    # Its own rc because absence means OPPOSITE things at the two call sites. `stack_up` installs the
    # firewall BEFORE compose, so on a first-ever `up` the jump legitimately does not exist yet (see
    # apply_tor_egress_iptables' own note) — alarming there would cry wolf on every fresh install.
    # doctor only runs this with the stack already up, where a missing jump IS the orphaned chain.
    local fwd
    fwd=$(sudo -n iptables -S FORWARD 2>/dev/null) || return 4
    grep -qF -- '-j DOCKER-USER' <<<"$fwd" || return 4
    return 0
}

# An install may only CLAIM success once the kernel agrees. Every failure line carries a stable
# `egress-apply:<reason>` token because the #2059 diagnostics read a BOUNDED journal excerpt — a
# token is what lets that excerpt name which exit fired instead of leaving the next battery to
# guess between exits that need opposite fixes.
tor_egress_verify_or_warn() { # <success message>
    local rc=0
    tor_egress_enforced || rc=$?
    case "$rc" in
    0) log "$1" ;;
    1) warn "egress-apply:verify-absent — the Tor-egress rules installed without error but are NOT in the live ruleset. Clearnet egress is NOT fail-closed." ;;
    2) warn "egress-apply:verify-no-tool — the Tor-egress rules cannot be read back because the backend's tool is not on PATH. Clearnet egress is NOT fail-closed." ;;
    # A missing jump is only benign BEFORE the network exists. `stack_up` installs ahead of compose
    # on a first-ever `up`, and Docker adds the FORWARD -> DOCKER-USER jump with its first network —
    # alarming there would cry wolf on every fresh install. But this same function is reached from
    # `apply`, `upgrade` and `reset-dashboard` (40-apply-and-render.sh, 03-release-verify.sh,
    # 16-reset.sh), which normally run against an ALREADY-RUNNING stack — where the engine has long
    # since had its chance and a vanished jump is a live fail-open, right now. Keying on the stack
    # itself is what separates the two; a silent `log` in the second case is an apply that should
    # have alarmed and did not.
    4)
        # mining_stack_running, NOT container_is_running tor. Tor can be down while p2pool/monerod/
        # xmrig-proxy keep running — a live, clearnet-capable stack — and keying on tor reported
        # that as the benign first-boot case. Measured on exactly that state before this change.
        if mining_stack_running; then
            warn "egress-apply:jump-missing — the Tor-egress rules are installed but NOTHING JUMPS TO DOCKER-USER while the stack is running. Clearnet egress is NOT fail-closed."
        else
            log "Tor-egress rules staged in DOCKER-USER; they take effect once the container engine adds its FORWARD jump. 'pithead doctor' verifies it against the running stack."
        fi
        ;;
    # Reachable and present, but something foreign sits above our DROP. We cannot say the drop is
    # what decides, so we do not say "enforced" — on either call path.
    5) warn "egress-apply:shadowed — a rule that is not ours sits ABOVE the Tor-egress DROP in DOCKER-USER, so the DROP may never be reached. Clearnet egress is NOT provably fail-closed. Inspect with 'sudo iptables -S DOCKER-USER'." ;;
    *) warn "egress-apply:verify-unreadable — the Tor-egress rules installed, but reading them back needs passwordless sudo, so enforcement is UNPROVEN." ;;
    esac
}

# Remove every rule we previously installed — idempotent, config-agnostic, engine-agnostic. Clears
# BOTH backends so a re-apply (or an engine change) can't leave a stale set behind: drop the nft
# table if present, then delete the tagged DOCKER-USER rules if present.
remove_tor_egress_firewall() {
    if command -v nft >/dev/null 2>&1; then
        sudo nft delete table inet "$TOR_EGRESS_NFT_TABLE" 2>/dev/null || true
    fi
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

# Install (or re-install, idempotently) the fail-closed Tor-only egress rules. Reads the toggle +
# subnet from .env so it works in the `up` path (where config.json isn't re-parsed). Branches to the
# engine's forward-hook mechanism: nftables under podman/netavark, DOCKER-USER under Docker.
apply_tor_egress_firewall() {
    local enabled subnet tor_ip
    enabled=$(env_get TOR_EGRESS_FIREWALL 2>/dev/null)
    [ -n "$enabled" ] || enabled=true
    remove_tor_egress_firewall # clear stale rules so a re-apply is idempotent
    if [ "$(normalize_bool "$enabled")" != "true" ]; then
        warn "Tor-only egress firewall is OFF (network.tor_egress_firewall=false) — a misconfigured app could reach clearnet."
        return 0
    fi
    subnet=$(env_get NETWORK_SUBNET 2>/dev/null)
    [ -n "$subnet" ] || subnet="172.28.0.0/24"
    tor_ip=$(env_get NETWORK_PREFIX 2>/dev/null)
    [ -n "$tor_ip" ] || tor_ip="172.28.0"
    tor_ip="${tor_ip}.25"
    if [ "$(container_engine)" = "podman" ]; then
        apply_tor_egress_nft "$subnet" "$tor_ip"
    else
        apply_tor_egress_iptables "$subnet" "$tor_ip"
    fi
}

# Appliance/netavark path: load the independent nft table (atomic, idempotent-replace), then PROVE
# it landed before saying so.
apply_tor_egress_nft() { # <subnet> <tor_ip>
    local subnet="$1" tor_ip="$2" br rc=0
    if ! command -v nft >/dev/null 2>&1; then
        warn "egress-apply:nft-missing — nftables not found, cannot enforce Tor-only egress. The stack runs, but clearnet egress is NOT fail-closed."
        return 0
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
        return 0
    fi
    if ! render_tor_egress_nft "$subnet" "$tor_ip" "$br" | sudo nft -f - 2>/dev/null; then
        warn "egress-apply:nft-load-failed — could not install the Tor-egress firewall (needs root + nftables). Stack runs, but clearnet egress is NOT fail-closed."
        return 0
    fi
    tor_egress_verify_or_warn "Tor-only egress enforced: clearnet dials from $subnet${br:+ (IPv4) and via $br (IPv6)} dropped except via Tor ($tor_ip)."
}

# DIY/Docker path: insert the tagged rules into DOCKER-USER, which Docker jumps to from FORWARD.
apply_tor_egress_iptables() { # <subnet> <tor_ip>
    local subnet="$1" tor_ip="$2" pos=1 rule
    if ! command -v iptables >/dev/null 2>&1; then
        warn "egress-apply:iptables-missing — iptables not found, cannot enforce Tor-only egress. The stack runs, but clearnet egress is NOT fail-closed."
        return 0
    fi
    # DOCKER-USER may not exist yet on a first-ever `up` (Docker creates it with its first network).
    # Pre-create it so installing here — before compose runs — succeeds; Docker adopts the existing
    # chain and adds the FORWARD jump. Harmless (-N fails with rc 1) once the chain is already there.
    sudo iptables -N DOCKER-USER 2>/dev/null || true
    while IFS= read -r rule; do
        # shellcheck disable=SC2086  # intentional word-splitting of the rule body
        if ! sudo iptables -I DOCKER-USER "$pos" -m comment --comment "$TOR_EGRESS_TAG" $rule 2>/dev/null; then
            warn "egress-apply:iptables-insert-failed — could not install the Tor-egress firewall (needs root + iptables). Stack runs, but clearnet egress is NOT fail-closed."
            remove_tor_egress_firewall
            return 0
        fi
        pos=$((pos + 1))
    done < <(tor_egress_rules "$subnet" "$tor_ip")
    tor_egress_verify_or_warn "Tor-only egress enforced: clearnet dials from $subnet dropped except via Tor ($tor_ip)."
}
