# shellcheck shell=bash
#
# The "clearnet THROUGH Tor" control dial that pairs with every "direct clearnet dial is DROPPED"
# row (#270/#2059). Shared by the e2e harness (run-state.sh, docker) and the appliance battery
# (tests/os/appliance-egress-leg.sh, podman), so the two cannot drift.
#
# WHY IT RETRIES (#2619). One stream through a random live exit fails now and then: bench-ci jobs
# 872 and 882 each lost the single dial to exit connect retries while the DROP row beside it
# passed and the rest of the stack's Tor traffic flowed. So the control gets
# TOR_CONTROL_DIAL_ATTEMPTS attempts, each with its own SOCKS username. Tor isolates streams by
# SOCKS auth by default (IsolateSOCKSAuth), so each attempt gets a fresh circuit and usually a
# different exit. A retry on the same circuit would hit the same bad exit. The assertion stays strict:
# it fails only when every attempt fails. The DROP half stays single-shot, because a timeout
# is the result it expects.

TOR_CONTROL_DIAL_ATTEMPTS=3
TOR_CONTROL_DIAL_TIMEOUT=45

# Print the host-side command that dials 1.1.1.1 from monerod through Tor's SOCKS at <socks>.
# It exits 0 on the first attempt that connects, 1 when all of them fail. `$$` (the in-container
# shell's pid) keeps the usernames of one call distinct from the previous call's, so a rerun in
# the same job does not reuse a circuit it just watched fail.
tor_control_dial_cmd() { # <engine: docker|podman> <socks host:port>
    local engine="$1" socks="$2"
    printf "%s exec monerod sh -c 'i=0; while [ \$i -lt %s ]; do i=\$((i + 1)); curl -s -o /dev/null -m %s --proxy-user \"pithead-control-\$\$-\$i:x\" --socks5-hostname %s http://1.1.1.1/ && exit 0; done; exit 1'" \
        "$engine" "$TOR_CONTROL_DIAL_ATTEMPTS" "$TOR_CONTROL_DIAL_TIMEOUT" "$socks"
}

# The failure text's attempt count, so a red reads "3 attempts, each on a fresh circuit, all
# failed" rather than looking like one unlucky stream.
tor_control_dial_attempts_text() {
    printf '%s attempts of %ss, each on a fresh Tor circuit, all failed' \
        "$TOR_CONTROL_DIAL_ATTEMPTS" "$TOR_CONTROL_DIAL_TIMEOUT"
}
