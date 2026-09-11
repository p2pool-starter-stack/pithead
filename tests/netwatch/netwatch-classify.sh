#!/usr/bin/env bash
# shellcheck shell=bash
# netwatch-classify.sh — decide, for each observed network flow, whether the CONFIG permits it.
#
# The passive half of the tier-4 egress/ingress story. Every existing check is an ACTIVE PROBE:
# dial a thing, see what happens (the appliance battery's Tor-egress dials, run-state.sh's firewall
# rows, bench-verify-egress.sh's socket sampling). Those answer "is THIS dial blocked?". None can answer
# "did anything else leave while we weren't dialling" — which is the question an operator actually
# has about a privacy product. This classifies a passive recording of everything that crossed the
# wire during a battery, and is the only part of the pipeline that decides expected vs unexpected.
#
# Recorder-agnostic by design. It reads a normalized flow record on stdin, one flow per line:
#
#     <proto>\t<src>\t<dst>\t<dport>\t<count>
#
# so the capture tool can be chosen or swapped without touching the judgement. Whatever produces
# those lines MUST aggregate: a mining box over a 90-minute battery emits tens of thousands of
# events, and CLAUDE.md forbids raw dumps reaching model context. One line per unique
# (proto, src, dst, dport) plus a count is the contract.
#
# THE DEFAULT VERDICT IS UNEXPECTED. A classifier that silently passes what it does not recognise
# is the exact false-green this exists to kill — it would report a clean run on a box leaking over
# a protocol nobody thought to allow-list. Every EXPECTED verdict below is an explicit, named rule.
# Anything matching none of them is `unclassified`, which fails.
#
# The allow-rules are written HERE, by hand, against config axes — never derived from .env, the
# rendered compose, or tor_egress_rules(). Generating the expectation from the same renderer that
# produced the behaviour asks the renderer to grade its own homework: both would agree on a wrong
# value and the audit would pass. This file therefore duplicates knowledge that exists elsewhere in
# the tree on purpose. The duplication IS the independence.

# --- IP predicates ----------------------------------------------------------------------------
# Pure, arg-only, no I/O, so they unit-test with no network. IPv4-only by design (mining_net is
# IPv4-only — lib/pithead/02-tor-egress.sh), but an IPv6 literal must never silently read as public
# OR as private: ip_is_private returns 2 for "not an IPv4 literal" so the classifier can route v6
# to its own explicit rule instead of guessing.

ip_is_ipv4() { # <addr>
    case "$1" in
    *[!0-9.]* | "") return 1 ;;
    esac
    local o n=0 IFS=.
    for o in $1; do
        [ -n "$o" ] && [ "$o" -le 255 ] 2>/dev/null || return 1
        n=$((n + 1))
    done
    [ "$n" -eq 4 ]
}

# rc 0 = private/reserved (a LAN, loopback, link-local or multicast destination)
# rc 1 = public
# rc 2 = not an IPv4 literal
# Ranges mirror the firewall's allow-set plus the ones it never sees because they are not forwarded.
# Spelled out rather than looped over a CIDR list: a mask parser is more code and more to get wrong
# than seven globs, and these ranges are fixed by RFC, not by config.
ip_is_private() { # <addr>
    ip_is_ipv4 "$1" || return 2
    case "$1" in
    10.* | 192.168.* | 127.* | 169.254.*) return 0 ;;
    172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].*) return 0 ;;                          # 172.16/12
    100.6[4-9].* | 100.[7-9][0-9].* | 100.1[0-1][0-9].* | 100.12[0-7].*) return 0 ;; # 100.64/10
    22[4-9].* | 23[0-9].*) return 0 ;;                                               # 224/4 multicast
    0.0.0.0 | 255.255.255.255) return 0 ;;
    esac
    return 1
}

# Is <addr> inside <prefix>, where prefix is the first three octets ("172.28.0")? mining_net is a
# /24 by construction (network.subnet is validated as one), so a prefix compare IS the subnet test.
# No mask arithmetic, and it cannot drift from how the rest of the tree spells the subnet.
ip_in_prefix() { # <addr> <prefix>
    case "$1" in "$2".*) return 0 ;; esac
    return 1
}

# --- the judgement ----------------------------------------------------------------------------
# Every rule names itself in its verdict, so a report says WHICH rule admitted a flow rather than
# just that something did. A reviewer can then argue with one rule instead of the whole classifier.
#
# Inputs describe the vantage point and come from the recording's sidecar metadata — never read off
# the box under test, which is the thing being audited.
#   NW_PREFIX      mining_net's first three octets, e.g. 172.28.0
#   NW_TOR_IP      the Tor container's address, e.g. 172.28.0.25
#   NW_BOX_IP      the box/guest address as seen from the vantage point
#   NW_VANTAGE_IP  the harness's own address (the KVM host's virbr0 gateway, or the e2e driver).
#                  Its traffic to the box is the TEST RIG talking, not the product.
#   NW_INGRESS_OK  space-separated inbound ports the config permits (netwatch_expected_ingress)
#
# Prints "<verdict>\t<rule>"; rc 0 for EXPECTED, rc 1 for UNEXPECTED.
netwatch_classify() { # <proto> <src> <dst> <dport>
    local proto="$1" src="$2" dst="$3" dport="$4"

    # --- ingress: something outside talking TO the box -----------------------------------------
    if [ "$dst" = "$NW_BOX_IP" ]; then
        if [ -n "${NW_VANTAGE_IP:-}" ] && [ "$src" = "$NW_VANTAGE_IP" ]; then
            # The harness's own SSH and HTTPS probes. Admitted because it is the test rig, and
            # scoped to the vantage address so a THIRD party hitting the same ports still fails.
            case " ${NW_INGRESS_OK:-} 22 443 " in
            *" $dport "*)
                printf 'EXPECTED\tingress-harness\n'
                return 0
                ;;
            esac
            printf 'UNEXPECTED\tingress-harness-unexpected-port\n'
            return 1
        fi
        case " ${NW_INGRESS_OK:-} " in
        *" $dport "*)
            printf 'EXPECTED\tingress-config-permits\n'
            return 0
            ;;
        esac
        printf 'UNEXPECTED\tingress-port-not-in-config\n'
        return 1
    fi

    # --- egress from the Tor container --------------------------------------------------------
    # Tor is the ONLY thing that may reach the public internet. That is the product's whole claim,
    # so this rule is deliberately broad — and deliberately keyed on the exact source address.
    if [ "$src" = "$NW_TOR_IP" ]; then
        printf 'EXPECTED\tegress-tor-relay\n'
        return 0
    fi

    # --- egress from the box itself -----------------------------------------------------------
    if [ "$src" = "$NW_BOX_IP" ]; then
        # NTP is real clearnet the OS originates. Named rather than folded into a generic bucket so it
        # stays visible in the report — it is a privacy fact an operator may want to argue with, not
        # noise to hide.
        if [ "$dport" = 123 ]; then
            printf 'EXPECTED\tegress-box-ntp\n'
            return 0
        fi
        # A DNS query to anything but the resolver this box was handed IS a leak — and one that no
        # /proc/net/tcp sampling can ever see, because it is UDP.
        if [ "$dport" = 53 ]; then
            if [ -n "${NW_RESOLVER_IP:-}" ] && [ "$dst" = "$NW_RESOLVER_IP" ]; then
                printf 'EXPECTED\tegress-box-dns\n'
                return 0
            fi
            printf 'UNEXPECTED\tDNS-LEAK-to-unexpected-resolver\n'
            return 1
        fi
        if ip_is_private "$dst"; then
            printf 'EXPECTED\tegress-box-lan\n'
            return 0
        fi
        # Plaintext HTTP to a public address. Tor never speaks it outbound and the OS-update check is
        # HTTPS, so there is no benign source for this — and it is the exact shape of the #2059 probe
        # dial. Caught at the perimeter even though the perimeter cannot say WHICH container sent it.
        if [ "$dport" = 80 ]; then
            printf 'UNEXPECTED\tCLEARNET-PLAINTEXT-HTTP-egress\n'
            return 1
        fi
        # HOST vantage: the recorder shares the machine with the containers, so a flow sourced from the
        # box itself is the HOST's own traffic (the update check), not the product's.
        if [ "${NW_MODE:-host}" = host ]; then
            if [ "$dport" = 443 ]; then
                printf 'EXPECTED\tegress-host-service\n'
                return 0
            fi
            printf 'UNEXPECTED\tegress-host-unexpected-port\n'
            return 1
        fi
        # PERIMETER vantage (the KVM host watching virbr0): podman inside the guest masquerades
        # 172.28.0.x to the guest address before traffic reaches the NIC, so the whole stack arrives as
        # ONE source and Tor's relay traffic is indistinguishable by tuple from anything else encrypted.
        # Admitting these silently would let a green read as "no leak", which this vantage cannot prove.
        # They are admitted but counted under a name that says so, and netwatch_report prints the total
        # as an explicit stated limit of the run.
        printf 'EXPECTED\tperimeter-unattributable\n'
        return 0
    fi

    # --- egress from a mining_net container that is NOT Tor -----------------------------------
    if ip_in_prefix "$src" "$NW_PREFIX"; then
        # It may reach Tor and the LAN; nothing else. A public destination here is the #2059
        # defect — observed passively rather than probed for.
        if [ "$dst" = "$NW_TOR_IP" ] || ip_in_prefix "$dst" "$NW_PREFIX"; then
            printf 'EXPECTED\tegress-intra-mining-net\n'
            return 0
        fi
        if ip_is_private "$dst"; then
            printf 'EXPECTED\tegress-mining-lan\n'
            return 0
        fi
        printf 'UNEXPECTED\tCLEARNET-LEAK-from-mining-net\n'
        return 1
    fi

    # Matched no rule. Never silently admitted — see the header.
    printf 'UNEXPECTED\tunclassified-%s\n' "$proto"
    return 1
}

# The hand-written port -> config-axis map. Every entry names the axis that opens it so a reviewer
# can check this against docs/configuration.md rather than against the code that binds the port.
# Prints the permitted inbound ports, space separated.
#
# Note how short this list is, and why: almost every service binds 127.0.0.1 (monerod RPC/ZMQ,
# wallet-rpc, Tari gRPC/wallet, both docker proxies), so it is not reachable from the vantage point
# at all. Only sshd, Caddy and the stratum are externally bound. Anything else answering from
# outside is a real finding, which is what makes the ingress half of this audit sharp.
netwatch_expected_ingress() { # <config.json>
    local cfg="$1" ports="22" # sshd — the appliance's own admin channel, always open
    local secure stratum_port rpc_lan grpc_lan tari_mode monero_mode
    secure=$(jq -r '.dashboard.secure // true' "$cfg" 2>/dev/null)
    stratum_port=$(jq -r '.p2pool.stratum_port // 3333' "$cfg" 2>/dev/null)
    rpc_lan=$(jq -r '.monero.rpc_lan_access // false' "$cfg" 2>/dev/null)
    grpc_lan=$(jq -r '.tari.grpc_lan_access // false' "$cfg" 2>/dev/null)
    monero_mode=$(jq -r '.monero.mode // "local"' "$cfg" 2>/dev/null)
    tari_mode=$(jq -r '.tari.mode // "local"' "$cfg" 2>/dev/null)

    # dashboard.secure decides 443-with-redirect vs plain 80. BOTH are open in secure mode: the
    # :80 -> TLS redirect is documented behaviour the provision phase already asserts.
    if [ "$secure" = "false" ]; then ports="$ports 80"; else ports="$ports 80 443"; fi
    # stratum_tls changes what is SERVED on the stratum port, not whether it is open.
    ports="$ports $stratum_port"
    [ "$rpc_lan" = "true" ] && [ "$monero_mode" = "local" ] && ports="$ports 18081"
    [ "$grpc_lan" = "true" ] && [ "$tari_mode" = "local" ] && ports="$ports 18142"
    printf '%s' "$ports"
}

# Read normalized flow records on stdin, print a bounded report, rc 1 on any unexpected flow.
# Bounded because the recording is large and the report is read by humans and models: every
# unexpected flow is listed in full (that IS the finding) while expected flows collapse to one
# count per rule.
netwatch_report() {
    local proto src dst dport count verdict rule line bad=0 seen=0
    local -a unexpected=()
    local -A tally=()
    while IFS=$'\t' read -r proto src dst dport count; do
        [ -n "$proto" ] || continue
        seen=$((seen + 1))
        line=$(netwatch_classify "$proto" "$src" "$dst" "$dport") || bad=$((bad + 1))
        verdict=${line%%$'\t'*}
        rule=${line#*$'\t'}
        tally["$rule"]=$((${tally["$rule"]:-0} + 1))
        [ "$verdict" = UNEXPECTED ] &&
            unexpected+=("$proto $src -> $dst:$dport  x$count  [$rule]")
    done
    # A recording with NO flows is a DEAD INSTRUMENT, not a clean network. The two look identical
    # in every other respect, so the empty case must fail loudly rather than read as success.
    if [ "$seen" -eq 0 ]; then
        printf 'netwatch: NO FLOWS RECORDED — the capture is dead, not the network clean.\n' >&2
        return 2
    fi
    printf 'netwatch: %d unique flows observed\n' "$seen"
    for rule in "${!tally[@]}"; do printf '  %6d  %s\n' "${tally[$rule]}" "$rule"; done | sort -rn
    # State the limit of the run in the run's own output. At the perimeter vantage these flows were
    # admitted because they COULD NOT BE JUDGED, not because they were shown to be Tor — and a
    # reader who does not see that number will read the green below as "no leak", which this vantage
    # cannot prove. Printing it beside the verdict is the difference between a measurement and a
    # reassurance.
    if [ "${tally[perimeter - unattributable]:-0}" -gt 0 ]; then
        printf '  note: %d flow(s) were unattributable at this vantage (the guest NATs the stack behind one address),\n' \
            "${tally[perimeter - unattributable]}"
        printf '        so they are counted, not cleared — a green verdict here does not prove they were Tor.\n'
    fi
    if [ "$bad" -gt 0 ]; then
        printf '\nnetwatch: %d UNEXPECTED flow(s):\n' "$bad"
        printf '  %s\n' "${unexpected[@]}"
        return 1
    fi
    printf 'netwatch: every observed flow is permitted by the config.\n'
}
