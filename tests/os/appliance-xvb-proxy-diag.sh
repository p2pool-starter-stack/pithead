# shellcheck shell=bash
# Sourced by appliance-xvb-routing-leg.sh; kept apart to hold that file under its budget.

# #2733 (jobs 1211, 1863, 1920, 2183): the restore died to a ConnectTimeout / "No route to host" on
# the proxy API while the journal showed the container running for most of the window, and the
# retained evidence could not say whether the container was down or its address was unreachable
# from the dashboard. Bounded read-only diagnostics name the container's state, a plain TCP connect
# from the dashboard to the same address the actuator dials, and the proxy's last log lines.
# Never restart the proxy for diagnostics: the sync gate owns its lifecycle.
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

# One diagnostic field: run "$@" (an _ssh or _xvb_guest_python call), keep its last <lines> of stdout.
# The real _ssh sends the client's stderr to SSH_ERR, not to the pipe, so the exit status and SSH_ERR
# are read right here, before the next call overwrites them: a failed collection is reported by name
# (rc and the transport's own words), never as an empty field a reader could take for "fine".
_xvb_diag_field() { # <text-when-empty> <lines> <cmd...>
    local empty="$1" lines="$2" out rc
    shift 2
    out="$("$@")"
    rc=$?
    out="$(printf '%s' "$out" | tr -d '\r' | tail -n "$lines" | tr '\n' ';')"
    if [ "$rc" -ne 0 ]; then
        printf 'collect-failed rc=%s %s %s' "$rc" "$out" "$(_xvb_guest_stderr)"
    else
        printf '%s' "${out:-$empty}"
    fi
}

_xvb_proxy_diag() { # -> one line: state | tcp | proxy log tail
    printf 'proxy diag: state[%s] tcp[%s] log[%s]' \
        "$(_xvb_diag_field empty 1 _ssh "podman inspect -f '{{.State.Status}} exit={{.State.ExitCode}} err={{.State.Error}}' xmrig-proxy 2>&1")" \
        "$(_xvb_diag_field empty 1 _xvb_guest_python "$(_xvb_proxy_diag_payload)")" \
        "$(_xvb_diag_field empty 3 _ssh "podman logs --tail 3 xmrig-proxy 2>&1")"
}

# The REAL _ssh shape (stderr into SSH_ERR) over a stubbed transport, so a collector that drops
# errors fails here: a dead transport and a dead dashboard exec must each be named in their field.
_xvb_diag_self_test() {
    local f=0 out SSH_ERR XVBT_WIRE
    SSH_ERR="$(mktemp)"
    _ssh() { "$XVBT_WIRE" "$@" 2>"$SSH_ERR"; }
    _xvb_wire_dead() { printf 'ssh: connect to host: No route to host\n' >&2 && return 255; }
    _xvb_wire_noexec() {
        case "$1" in
        *"podman exec"*) printf 'Error: dashboard is not running\n' >&2 && return 125 ;;
        *) printf 'live\n' ;;
        esac
    }
    XVBT_WIRE=_xvb_wire_dead
    out="$(_xvb_proxy_diag)"
    [ "$(printf '%s' "$out" | grep -o 'collect-failed rc=255 .*No route to host' | wc -l)" -ge 1 ] &&
        [[ "$out" == *'tcp[collect-failed rc=255 '* ]] || {
        printf 'xvb self-test: a dead transport is not named in the diagnostic: %s\n' "$out" >&2
        f=$((f + 1))
    }
    XVBT_WIRE=_xvb_wire_noexec
    out="$(_xvb_proxy_diag)"
    [[ "$out" == *'state[live]'* && "$out" == *'tcp[collect-failed rc=125 '*'dashboard is not running'*']'* &&
        "$out" == *'log[live]'* ]] || {
        printf 'xvb self-test: a dead dashboard exec is not named in the tcp field: %s\n' "$out" >&2
        f=$((f + 1))
    }
    unset -f _ssh _xvb_wire_dead _xvb_wire_noexec
    _xvb_diag_payload_self_test || f=$((f + 1))
    rm -f "$SSH_ERR"
    [ "$f" -eq 0 ]
}

# Self-test helper: <msgs-file> -> 0 when every row that names an unreachable proxy carries the diagnostic.
_xvb_diag_rows_ok() {
    ! grep -E '^(controller actuator could not|bounded controller injection did not leave|xmrig-proxy API never|guest left routed|sync gate never read released)' "$1" |
        grep -qv 'proxy diag: state\[' || {
        printf 'xvb self-test: a proxy-unreachable red row lacks the proxy diagnostic (#2733)\n' >&2
        return 1
    }
}

# The REAL payload, executed: the dashboard package importable (so PROXY_HOST / PROXY_API_PORT resolve
# from the actual config module) against a local listener, then against the same port once closed.
# A broken import or a renamed constant makes the child die, and its output then misses both patterns.
_xvb_diag_payload_self_test() {
    local root out
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    out="$(PAYLOAD="$(_xvb_proxy_diag_payload | base64 -d)" ROOT="$root" python3 -c '
import os, socket, subprocess, sys
def run(port):
    env = {**os.environ, "PYTHONPATH": os.environ["ROOT"] + "/dashboard", "PROXY_HOST": "127.0.0.1", "PROXY_API_PORT": str(port)}
    r = subprocess.run([sys.executable, "-"], input=os.environ["PAYLOAD"], capture_output=True, text=True, env=env)
    return (r.stdout.strip() or "no-output rc=%s %s" % (r.returncode, r.stderr.strip()[-120:])).replace("\n", ";")
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
port = s.getsockname()[1]
print(run(port))
s.close()
print(run(port))
' 2>&1)"
    [ "$(printf '%s\n' "$out" | sed -n 1p)" = tcp-ok ] &&
        [[ "$(printf '%s\n' "$out" | sed -n 2p)" == tcp-ConnectionRefusedError:* ]] || {
        printf 'xvb self-test: the real TCP diagnostic payload did not report reachable then refused: %s\n' "$out" >&2
        return 1
    }
}
