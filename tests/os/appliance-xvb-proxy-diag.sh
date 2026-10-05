# shellcheck shell=bash
# Sourced by appliance-xvb-routing-leg.sh; kept apart to hold that file under its budget.

# #2733 (jobs 1211, 1863, 1920, 2183): the restore died to a ConnectTimeout / "No route to host" on
# the proxy API while the journal showed the container running for most of the window, and the
# leg's own `podman start` output was thrown away, so the retained evidence could not say whether
# the start failed, the container was down, or the address was unreachable from the dashboard. One
# bounded read per red row names which: the container's state, what a fresh `podman start` says,
# a plain TCP connect from the dashboard container to the same address the actuator dials, and the
# proxy's own last log lines. Read-only apart from the start the leg already re-asserts every poll.
_xvb_proxy_diag_payload() {
    printf '%s\n' "import socket" \
        "from mining_dashboard.config.config import PROXY_API_PORT, PROXY_HOST" \
        "try:" \
        "    socket.create_connection((PROXY_HOST, PROXY_API_PORT), 3).close()" \
        "    print('tcp-ok')" \
        "except OSError as e:" \
        "    print('tcp-' + type(e).__name__ + ':' + str(e))" |
        base64 | tr -d '\n'
}

_xvb_proxy_diag() { # -> one line: state | start | tcp | proxy log tail
    local state start tcp logs
    state="$(_ssh "podman inspect -f '{{.State.Status}} exit={{.State.ExitCode}} err={{.State.Error}}' xmrig-proxy 2>&1" 2>&1 | tr -d '\r' | tail -1)"
    start="$(_ssh "podman start xmrig-proxy 2>&1 >/dev/null | tail -2" 2>&1 | tr -d '\r' | tr '\n' ' ')"
    tcp="$(_xvb_guest_python "$(_xvb_proxy_diag_payload)" 2>&1 | tail -1)"
    logs="$(_ssh "podman logs --tail 3 xmrig-proxy 2>&1" 2>&1 | tr -d '\r' | tr '\n' ';')"
    printf 'proxy diag: state[%s] start[%s] tcp[%s] log[%s]' "$state" "${start:-ok}" "${tcp:-none}" "$logs"
}

# Self-test helper: <msgs-file> <want> -> 0 when exactly <want> red rows carry the full diagnostic.
_xvb_diag_rows_ok() {
    [ "$(grep -c 'proxy diag: state\[stub-proxy-state\] start\[.*\] tcp\[tcp-timeout:timed out\] log\[stub-proxy-state;\]' "$1")" = "$2" ] ||
        { printf 'xvb self-test: the red rows do not carry the proxy diagnostic (#2733)\n' >&2 && return 1; }
}
