#!/usr/bin/env bash
# netwatch.sh — record every flow that crosses the bench during a tier-4 battery, then judge it.
#
#   netwatch.sh start  --out DIR [--vantage IP] [--box IP] [--prefix P] [--tor-ip IP]
#   netwatch.sh stop   --out DIR
#   netwatch.sh verify --out DIR --config config.json
#   netwatch.sh --self-test
#
# Runs alongside tests/os/run.sh and tests/integration/run.sh rather than inside them: the point is
# to see what happened while nobody was probing. The judgement lives in netwatch-classify.sh; this
# file only captures and normalizes, so the capture tool can change without touching the verdict.
#
# VANTAGE POINTS — and what each can honestly claim:
#
#   e2e / self-host: the recorder runs on the Docker host, which is also the container host, so
#   conntrack sees the PRE-NAT source. Attribution is exact: a flow from 172.28.0.26 is monerod.
#
#   KVM / appliance: the recorder runs on the KVM host and watches libvirt's virbr0. Podman INSIDE
#   the guest masquerades 172.28.0.x to the guest's own address before traffic reaches the virtual
#   NIC, so every flow appears to come from the guest. This vantage therefore proves "the guest
#   emitted this flow", NOT "this container did". It is still the right place to watch from — it is
#   outside the guest and nothing running on the appliance can influence or falsify it, and it sees
#   ingress in full — but per-container attribution on the appliance needs an in-guest recorder,
#   which is deliberately NOT built here (it would mean side-loading an image into the guest
#   mid-battery, and is its own change). Do not read a clean appliance run as per-container proof.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=tests/netwatch/netwatch-classify.sh
. "$HERE/netwatch-classify.sh"

NETWATCH_IMAGE=pithead-netwatch:test
ENGINE="${NETWATCH_ENGINE:-docker}"

_die() {
    printf 'netwatch: %s\n' "$1" >&2
    exit 2
}

# conntrack -E prints the ORIGINAL tuple first, then the reply tuple. Only the original is wanted:
# it carries the pre-NAT source, which is the whole reason this reads conntrack rather than a pcap.
# Taking the first src=/dst=/dport= per line does that — a second match would be the return path and
# would invent a flow that never existed. ICMP lines carry no dport; they normalize to 0 rather than
# being dropped, because an unclassified ICMP flow is a finding the classifier must still see.
netwatch_normalize() { # raw conntrack events on stdin -> "<proto>\t<src>\t<dst>\t<dport>\t<count>"
    awk '
        {
            proto=""; src=""; dst=""; dport="";
            for (i = 1; i <= NF; i++) {
                if (proto == "" && $i ~ /^(tcp|udp|icmp|icmpv6|sctp|dccp|unknown)$/) proto = $i
                else if (src   == "" && $i ~ /^src=/)   { src   = substr($i, 5) }
                else if (dst   == "" && $i ~ /^dst=/)   { dst   = substr($i, 5) }
                else if (dport == "" && $i ~ /^dport=/) { dport = substr($i, 7) }
            }
            if (proto == "" || src == "" || dst == "") next
            if (dport == "") dport = 0
            print proto "\t" src "\t" dst "\t" dport
        }
    ' | sort | uniq -c | awk '{ print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $1 }'
}

_cmd_start() {
    local out="" vantage="" box="" prefix="172.28.0" tor_ip=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --out) out="$2" && shift 2 ;;
        --vantage) vantage="$2" && shift 2 ;;
        --box) box="$2" && shift 2 ;;
        --prefix) prefix="$2" && shift 2 ;;
        --tor-ip) tor_ip="$2" && shift 2 ;;
        *) _die "unknown arg: $1" ;;
        esac
    done
    [ -n "$out" ] || _die "start needs --out DIR"
    mkdir -p "$out" || _die "cannot create $out"
    [ -n "$tor_ip" ] || tor_ip="$prefix.25"

    # The vantage metadata is captured HERE, from the caller, and never read off the box under test.
    # A box that is misconfigured about its own address would otherwise define the expectation that
    # is supposed to catch it.
    cat >"$out/meta.env" <<EOF
NW_PREFIX=$prefix
NW_TOR_IP=$tor_ip
NW_BOX_IP=$box
NW_VANTAGE_IP=$vantage
NW_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

    "$ENGINE" image inspect "$NETWATCH_IMAGE" >/dev/null 2>&1 ||
        _die "$NETWATCH_IMAGE is not built — run scripts/install-test-tools.sh"

    "$ENGINE" rm -f pithead-netwatch >/dev/null 2>&1
    # --network host + NET_ADMIN: conntrack must read the HOST's table, not a container's.
    #
    # Writes to a MOUNTED FILE, not to stdout for `docker logs` to hold. A battery runs 90 minutes
    # and a busy mining box emits events continuously; the docker log driver is a buffer with its
    # own rotation and truncation policy, so relying on it would make the recording's completeness a
    # property of the log driver's configuration on whichever bench happened to run it. Silent
    # truncation is the worst failure available here — it does not error, it just returns fewer
    # flows, and fewer flows is exactly what a clean verdict looks like.
    "$ENGINE" run -d --name pithead-netwatch --network host \
        --cap-add NET_ADMIN --cap-add NET_RAW \
        -v "$out:/out" --entrypoint sh \
        "$NETWATCH_IMAGE" -c 'exec conntrack -E -o extended >/out/raw.log 2>/out/capture.err' \
        >"$out/container.id" 2>"$out/start.err" ||
        _die "could not start the recorder: $(head -c 300 "$out/start.err" 2>/dev/null)"
    # Prove it is actually RECORDING, not merely created. A container that exits immediately (a bad
    # capability, a missing kernel module) leaves an empty raw.log, and an empty recording is
    # indistinguishable from a quiet network at verify time — which is the one failure this whole
    # tool must never have.
    sleep 2
    [ "$("$ENGINE" inspect -f '{{.State.Running}}' pithead-netwatch 2>/dev/null)" = true ] ||
        _die "the recorder exited immediately: $(head -c 300 "$out/capture.err" 2>/dev/null)"
    printf 'netwatch: recording to %s (vantage=%s box=%s)\n' "$out" "${vantage:-?}" "${box:-?}"
}

_cmd_stop() {
    local out=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --out) out="$2" && shift 2 ;;
        *) _die "unknown arg: $1" ;;
        esac
    done
    [ -n "$out" ] || _die "stop needs --out DIR"
    # The recorder must still have been ALIVE. If it died mid-battery, raw.log holds however much
    # it managed before dying and the verdict would be drawn over a window that silently ended
    # early — a partial recording reported as a complete one.
    local was_running
    was_running="$("$ENGINE" inspect -f '{{.State.Running}}' pithead-netwatch 2>/dev/null)"
    "$ENGINE" rm -f pithead-netwatch >/dev/null 2>&1
    [ -f "$out/raw.log" ] || _die "no recording at $out/raw.log — was start run?"
    [ "$was_running" = true ] ||
        _die "the recorder was NOT running at stop — the recording is partial and its window unknown: $(head -c 200 "$out/capture.err" 2>/dev/null)"
    netwatch_normalize <"$out/raw.log" >"$out/flows.tsv"
    printf 'NW_STOPPED=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$out/meta.env"
    printf 'netwatch: %s raw events -> %s unique flows\n' \
        "$(grep -c . <"$out/raw.log" 2>/dev/null || echo 0)" \
        "$(grep -c . <"$out/flows.tsv" 2>/dev/null || echo 0)"
}

_cmd_verify() {
    local out="" cfg=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --out) out="$2" && shift 2 ;;
        --config) cfg="$2" && shift 2 ;;
        *) _die "unknown arg: $1" ;;
        esac
    done
    [ -n "$out" ] && [ -f "$out/flows.tsv" ] || _die "verify needs --out DIR from a completed stop"
    [ -n "$cfg" ] && [ -f "$cfg" ] || _die "verify needs --config config.json"
    # shellcheck disable=SC1091 # written by _cmd_start
    . "$out/meta.env"
    export NW_PREFIX NW_TOR_IP NW_BOX_IP NW_VANTAGE_IP
    NW_INGRESS_OK="$(netwatch_expected_ingress "$cfg")"
    export NW_INGRESS_OK
    printf 'netwatch: window %s .. %s; ingress permitted by config: %s\n' \
        "${NW_STARTED:-?}" "${NW_STOPPED:-?}" "$NW_INGRESS_OK"
    netwatch_report <"$out/flows.tsv"
}

case "${1:-}" in
start)
    shift
    _cmd_start "$@"
    ;;
stop)
    shift
    _cmd_stop "$@"
    ;;
verify)
    shift
    _cmd_verify "$@"
    ;;
--self-test)
    exec bash "$HERE/netwatch-selftest.sh"
    ;;
*)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
