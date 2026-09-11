#!/usr/bin/env bash
# Self-test for netwatch-classify.sh. No network, no bench, no capture tool — it drives the
# judgement against seeded flows, which is the whole reason the classifier is recorder-agnostic.
#
# The seeds that matter are the NEGATIVE ones. A classifier is easy to write so that everything
# passes; what has to be proven is that each UNEXPECTED shape is actually caught, and that the
# catch is for the right reason (the rule name, not just the verdict).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=tests/netwatch/netwatch-classify.sh
. "$HERE/netwatch-classify.sh"

PASS=0 FAIL=0
NW_PREFIX=172.28.0
NW_TOR_IP=172.28.0.25
NW_BOX_IP=192.168.122.50
NW_VANTAGE_IP=192.168.122.1
NW_INGRESS_OK="22 80 443 3333"

# <expected-verdict> <expected-rule> <proto> <src> <dst> <dport> -- <why this case exists>
check() {
    local want_v="$1" want_r="$2" proto="$3" src="$4" dst="$5" dport="$6" why="${8:-}"
    local got_v got_r line
    line=$(netwatch_classify "$proto" "$src" "$dst" "$dport")
    got_v=${line%%$'\t'*}
    got_r=${line#*$'\t'}
    if [ "$got_v" = "$want_v" ] && [ "$got_r" = "$want_r" ]; then
        PASS=$((PASS + 1))
        printf '  ok   %-34s %s\n' "$want_r" "$why"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %-34s want [%s/%s] got [%s/%s]  %s\n' "$want_r" "$want_v" "$want_r" "$got_v" "$got_r" "$why"
    fi
}

echo "== the defect this exists to catch =="
# #2059 exactly: a mining container reaching a public address directly. If only ONE assertion in
# this file matters, it is this one.
check UNEXPECTED CLEARNET-LEAK-from-mining-net tcp 172.28.0.26 1.1.1.1 80 -- "monerod dials clearnet direct (#2059)"
check UNEXPECTED CLEARNET-LEAK-from-mining-net udp 172.28.0.28 8.8.8.8 53 -- "a DNS leak — UDP, which socket sampling cannot see at all"
check UNEXPECTED CLEARNET-LEAK-from-mining-net tcp 172.28.0.29 203.0.113.7 4444 -- "xmrig-proxy to an arbitrary public host"

echo "== what must still be allowed, or the audit is useless noise =="
check EXPECTED egress-tor-relay tcp 172.28.0.25 198.51.100.9 9001 -- "Tor to a real relay — the one thing that SHOULD reach the internet"
check EXPECTED egress-intra-mining-net tcp 172.28.0.26 172.28.0.25 9050 -- "monerod to Tor's SOCKS — the supported path"
check EXPECTED egress-intra-mining-net tcp 172.28.0.28 172.28.0.29 3333 -- "p2pool to xmrig-proxy, container to container"
check EXPECTED egress-mining-lan tcp 172.28.0.26 192.168.1.50 18081 -- "a remote-node config reaching a LAN monerod"

echo "== ingress =="
check EXPECTED ingress-config-permits tcp 203.0.113.9 192.168.122.50 3333 -- "a rig dialling the published stratum"
check EXPECTED ingress-harness tcp 192.168.122.1 192.168.122.50 22 -- "the harness's own SSH — test rig, not product"
check UNEXPECTED ingress-port-not-in-config tcp 203.0.113.9 192.168.122.50 18081 -- "monerod RPC answering from OUTSIDE (binds 127.0.0.1 — #1803's class)"
check UNEXPECTED ingress-port-not-in-config tcp 203.0.113.9 192.168.122.50 12375 -- "the docker proxy reachable externally — would be critical"
check UNEXPECTED ingress-harness-unexpected-port tcp 192.168.122.1 192.168.122.50 9999 -- "even the harness is scoped: a stray port is still a finding"

echo "== the box itself, HOST vantage (e2e: recorder shares the machine) =="
NW_MODE=host NW_RESOLVER_IP=192.168.122.1
check EXPECTED egress-box-dns udp 192.168.122.50 192.168.122.1 53 -- "DNS to the resolver it was handed"
check EXPECTED egress-box-lan tcp 192.168.122.50 192.168.122.1 5000 -- "the bench registry the appliance pulls from"
check EXPECTED egress-box-ntp udp 192.168.122.50 198.51.100.9 123 -- "NTP — real clearnet, named so it stays visible"
check UNEXPECTED egress-host-unexpected-port tcp 192.168.122.50 198.51.100.9 6667 -- "host dialling a public host on an unexplained port"
check UNEXPECTED DNS-LEAK-to-unexpected-resolver udp 192.168.122.50 8.8.8.8 53 -- "DNS to a resolver nobody configured — UDP, invisible to socket sampling"
check UNEXPECTED CLEARNET-PLAINTEXT-HTTP-egress tcp 192.168.122.50 1.1.1.1 80 -- "plaintext HTTP out — Tor never does this; the #2059 dial shape"

echo "== the box itself, PERIMETER vantage (KVM: the stack arrives NATed as one source) =="
# The whole stack behind one address. The rules above must still bite, and the rest must be
# admitted UNDER A NAME THAT SAYS IT WAS NOT JUDGED — never silently as if it had been cleared.
NW_MODE=perimeter
check UNEXPECTED CLEARNET-PLAINTEXT-HTTP-egress tcp 192.168.122.50 1.1.1.1 80 -- "the #2059 dial is STILL caught with no per-container attribution"
check UNEXPECTED DNS-LEAK-to-unexpected-resolver udp 192.168.122.50 8.8.8.8 53 -- "a DNS leak is still caught at the perimeter"
check EXPECTED perimeter-unattributable tcp 192.168.122.50 198.51.100.9 443 -- "TLS out: cannot be told from Tor here — admitted, but COUNTED as unjudged"
check EXPECTED perimeter-unattributable tcp 192.168.122.50 198.51.100.9 9001 -- "a relay ORPort, same story"
# The regression that would gut this: perimeter mode silently reusing the host rule and calling an
# unexplained public port EXPECTED without recording that it was never judged.
NW_MODE=host
check UNEXPECTED egress-host-unexpected-port tcp 192.168.122.50 198.51.100.9 9001 -- "the SAME flow is a finding at the host vantage, where it CAN be judged"
NW_MODE=perimeter

echo "== the default verdict is UNEXPECTED, not EXPECTED =="
# The false-green this classifier exists to avoid: a shape no rule covers must FAIL, never pass.
check UNEXPECTED unclassified-icmp icmp 10.9.9.9 10.8.8.8 0 -- "a flow touching neither box nor mining_net"
check UNEXPECTED unclassified-tcp tcp 2001:db8::1 2001:db8::2 443 -- "IPv6 is not silently read as private OR public"

echo "== ip_is_private: three-way, because two-way hides IPv6 =="
ip_is_private 10.1.2.3 && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    echo "  FAIL 10/8 is private"
}
ip_is_private 172.28.0.5 && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    echo "  FAIL 172.16/12 is private"
}
ip_is_private 100.64.0.1 && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    echo "  FAIL CGNAT is private"
}
! ip_is_private 1.1.1.1 && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    echo "  FAIL 1.1.1.1 is public"
}
# 172.15 and 172.32 sit either side of 172.16/12 — the classic glob off-by-one.
! ip_is_private 172.15.0.1 && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    echo "  FAIL 172.15 is PUBLIC (below the range)"
}
! ip_is_private 172.32.0.1 && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    echo "  FAIL 172.32 is PUBLIC (above the range)"
}
! ip_is_private 100.128.0.1 && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    echo "  FAIL 100.128 is PUBLIC (above CGNAT)"
}
! ip_is_private 100.63.0.1 && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    echo "  FAIL 100.63 is PUBLIC (below CGNAT)"
}
[ "$(
    ip_is_private 2001:db8::1 >/dev/null
    echo $?
)" = 2 ] && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    echo "  FAIL IPv6 returns 2, not 0/1"
}
[ "$(
    ip_is_private 999.1.1.1 >/dev/null
    echo $?
)" = 2 ] && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    echo "  FAIL a malformed quad returns 2"
}

echo "== an EMPTY recording is a dead instrument, not a clean network =="
# The single most likely way this whole feature reports a false green: the capture never armed,
# nothing was recorded, and "0 unexpected flows" reads as success.
out=$(printf '' | netwatch_report 2>&1)
rc=$?
[ "$rc" = 2 ] && case "$out" in *"NO FLOWS RECORDED"*) true ;; *) false ;; esac &&
    PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    echo "  FAIL empty input must rc 2 and say so (got rc=$rc: $out)"
}

echo "== netwatch_report end to end =="
printf 'tcp\t172.28.0.25\t198.51.100.9\t9001\t42\ntcp\t172.28.0.26\t172.28.0.25\t9050\t7\n' | netwatch_report >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    echo "  FAIL a clean recording must rc 0 (got $rc)"
}
leaky=$(printf 'tcp\t172.28.0.25\t198.51.100.9\t9001\t42\ntcp\t172.28.0.26\t1.1.1.1\t80\t3\n' | netwatch_report 2>&1)
rc=$?
[ "$rc" = 1 ] && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    echo "  FAIL one leak among clean flows must rc 1 (got $rc)"
}
# The leak must be NAMED in the report, not just counted — a count without the tuple is unactionable.
case "$leaky" in *"172.28.0.26 -> 1.1.1.1:80"*) PASS=$((PASS + 1)) ;;
*)
    FAIL=$((FAIL + 1))
    echo "  FAIL the report must name the offending flow"
    ;;
esac

echo "== netwatch_expected_ingress: the port map follows the config, both ways =="
cfg=$(mktemp)
printf '%s' '{"dashboard":{"secure":true},"p2pool":{"stratum_port":3333},"monero":{"mode":"local","rpc_lan_access":false},"tari":{"mode":"local","grpc_lan_access":false}}' >"$cfg"
got=$(netwatch_expected_ingress "$cfg")
case " $got " in *" 443 "*) PASS=$((PASS + 1)) ;; *)
    FAIL=$((FAIL + 1))
    echo "  FAIL secure=true opens 443 (got: $got)"
    ;;
esac
case " $got " in *" 18081 "*)
    FAIL=$((FAIL + 1))
    echo "  FAIL rpc_lan_access=false must NOT open 18081 (got: $got)"
    ;;
*) PASS=$((PASS + 1)) ;; esac
# The control: flipping the axis must MOVE the answer. Without this, the assertion above passes
# on a function that returns a constant and never reads the config at all.
printf '%s' '{"dashboard":{"secure":true},"p2pool":{"stratum_port":3333},"monero":{"mode":"local","rpc_lan_access":true},"tari":{"mode":"local","grpc_lan_access":true}}' >"$cfg"
got=$(netwatch_expected_ingress "$cfg")
case " $got " in *" 18081 "*) PASS=$((PASS + 1)) ;; *)
    FAIL=$((FAIL + 1))
    echo "  FAIL rpc_lan_access=true MUST open 18081 (got: $got)"
    ;;
esac
case " $got " in *" 18142 "*) PASS=$((PASS + 1)) ;; *)
    FAIL=$((FAIL + 1))
    echo "  FAIL grpc_lan_access=true MUST open 18142 (got: $got)"
    ;;
esac
rm -f "$cfg"

printf '\nnetwatch self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
