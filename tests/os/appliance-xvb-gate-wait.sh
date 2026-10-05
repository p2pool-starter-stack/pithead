# shellcheck shell=bash
# Sourced by appliance-xvb-routing-leg.sh; kept apart to hold that file under its budget.

# #2733: on this unsynced guest the #35 sync gate holds p2pool and xmrig-proxy stopped and re-stops
# the proxy every cycle (jobs 130, 2241: a stop every 30-45s for the whole leg). A leg that restarts
# the proxy against that hold fights the product and loses whenever the restarted proxy is not
# reachable before the next stop. The leg therefore runs only where the gate is released: after the
# reserved-node approval dials synced nodes (job 2241: the gate started both at 15:11:13, 6s after
# the commit) and before its restore re-holds them. This reads the gate the way the dashboard does:
# its persisted latch says released and no full sync-gate-reset marker overrides it (a Tari-only
# one keeps an earned release, data_gates.py). Read-only, as the integration sampler reads it: the
# dashboard's StateManager would open the live database for writing every poll.
_xvb_gate_payload() {
    printf '%s\n' "import json, os, sqlite3" \
        "from mining_dashboard.config.config import DB_FILE_PATH" \
        "from mining_dashboard.service.data_gates import SYNC_GATE_RESET_PATH as m" \
        "with sqlite3.connect('file:' + DB_FILE_PATH + '?mode=ro', uri=True, timeout=1) as db:" \
        "    row = db.execute('SELECT value FROM kv_store WHERE key = ?', ('snapshot_latest_data',)).fetchone()" \
        "snap = json.loads(row[0]) if row and row[0] else {}" \
        "marker = os.path.exists(m) and open(m, 'rb').read(32) != b'tari-only\\n'" \
        "print('released' if snap.get('miner_released') is True and not marker else 'held' + (' marker' if marker else ''))" |
        base64 | tr -d '\n'
}

# Two consecutive samples, as assert_mining_probe_ready does for the integration harness: one
# released reading with the proxy up can still be the instant before a re-hold. Never starts or
# stops a container: the gate owns them. Prints the last sample on timeout.
_xvb_wait_for_gate_release() { # -> 0 once released with xmrig-proxy running twice in a row
    local deadline payload gate running samples=0 last="unread"
    payload="$(_xvb_gate_payload)"
    deadline=$(($(date +%s) + ${XVB_GATE_RELEASE_TIMEOUT:-300}))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        gate="$(_xvb_guest_python "$payload" 2>/dev/null | tr -d '\r\n')"
        running="$(_ssh "podman inspect -f '{{.State.Running}}' xmrig-proxy" 2>/dev/null | tr -d '\r\n')"
        last="gate=${gate:-unreadable} proxy-running=${running:-unreadable}"
        if [ "$gate" = released ] && [ "$running" = true ]; then
            samples=$((samples + 1))
            [ "$samples" -ge 2 ] && return 0
        else
            samples=0
        fi
        sleep 5
    done
    printf '%s' "$last"
    return 1
}

# The order is the fix, so it is pinned on the REAL caller: the leg runs once the reserved-node
# approval applied and before its restore, a red leg still restores, an approval that never applied
# is one named red row instead of a 300s wait, and the leg is called nowhere else in the phase.
_xvb_gate_order_self_test() (
    local here calls want applied
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=tests/os/appliance-node-runtime-leg.sh
    . "$here/appliance-node-runtime-leg.sh"
    ok() { :; }
    bad() { calls+="bad "; }
    _reserved_node_regressions() { RESERVED_NODE_APPLIED=$applied; }
    phase_provision_xvb_routing() { calls+="xvb " && return 1; }
    approval_restore_pending() { calls+="restore "; }
    for want in "1|xvb restore " "0|bad restore "; do
        calls="" applied="${want%%|*}" APPROVAL_RESTORE_SNAPSHOT=snap
        phase_provision_remote_node_regressions user pass
        [ "$calls" = "${want#*|}" ] || {
            printf 'xvb self-test: approval=%s ran [%s], want [%s] (#2733)\n' "$applied" "$calls" "${want#*|}" >&2
            return 1
        }
    done
    grep -q 'node_ok=1 RESERVED_NODE_APPLIED=1' "$here/appliance-node-runtime-leg.sh" &&
        ! grep -q 'phase_provision_xvb_routing' "$here/phases/provision-initial.sh" || {
        printf 'xvb self-test: the XvB leg is not tied to the applied reserved-node approval alone (#2733)\n' >&2
        return 1
    }
)

# The REAL payload against the real dashboard modules: a seeded snapshot and marker in a temp dir.
_xvb_gate_payload_self_test() {
    local root out
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    out="$(PAYLOAD="$(_xvb_gate_payload | base64 -d)" PYTHONPATH="$root/dashboard" python3 -c '
import os, subprocess, sys, tempfile
d = tempfile.mkdtemp()
def run(snapshot, marker):
    db, mk = os.path.join(d, "s.db"), os.path.join(d, "reset")
    for p in (db, mk):
        if os.path.exists(p):
            os.remove(p)
    if marker:
        open(mk, "w").write("" if marker is True else marker)
    pre = "import mining_dashboard.service.data_gates as g, mining_dashboard.config.config as c, mining_dashboard.service.storage_service as s\n"
    pre += "g.SYNC_GATE_RESET_PATH = %r\nc.DB_FILE_PATH = %r\ns.StateManager(%r)\n" % (mk, db, db)
    if snapshot is not None:
        pre += "s.StateManager(%r).save_snapshot(%r)\n" % (db, snapshot)
    r = subprocess.run([sys.executable, "-c", pre + os.environ["PAYLOAD"]], capture_output=True, text=True)
    return r.stdout.strip() or "no-output rc=%s %s" % (r.returncode, r.stderr.strip()[-120:].replace("\n", ";"))
print(run({"miner_released": True}, False))
print(run({"miner_released": True}, True))
print(run({"miner_released": True}, "tari-only\n"))
print(run({"miner_released": False}, False))
print(run(None, False))
' 2>&1)"
    [ "$out" = "$(printf 'released\nheld marker\nreleased\nheld\nheld')" ] && _xvb_gate_payload | base64 -d | grep -q "mode=ro'" || {
        printf 'xvb self-test: the real gate payload misread the latch: %s\n' "$(printf '%s' "$out" | tr '\n' '|')" >&2
        return 1
    }
}

# The wait itself, over stubbed guest reads: <gate answers> <proxy answers> <want-rc> <label>.
# Each answers string is consumed one word per sample; the last word repeats.
_xvb_gate_wait_self_test() {
    local f=0 dir rc XVB_GATE_RELEASE_TIMEOUT=2 out saved
    saved="$(declare -f _xvb_guest_python _ssh)" # redefined below; put back for the caller's own tests
    dir="$(mktemp -d)"
    sleep() { command sleep 0.05; }
    _xvb_next() { # <file> <words>: the sample counter lives in a file, outside the $(...) subshells
        local n words
        n=$(($(cat "$1" 2>/dev/null || echo 0) + 1)) && printf '%s' "$n" >"$1"
        read -ra words <<<"$2"
        [ "$n" -le "${#words[@]}" ] || n=${#words[@]}
        printf '%s\n' "${words[$((n - 1))]}"
    }
    _xvb_guest_python() { _xvb_next "$dir/g" "$XVBT_GATE"; }
    _ssh() {
        case "$1" in *"podman inspect"*"xmrig-proxy"*) _xvb_next "$dir/p" "$XVBT_PROXY" ;; *"podman start"* | *"podman stop"*) echo "$1" >>"$dir/touched" ;; esac
    }
    while IFS='|' read -r XVBT_GATE XVBT_PROXY want label; do
        rm -f "$dir/g" "$dir/p"
        rc=0 && out="$(_xvb_wait_for_gate_release)" || rc=$?
        [ "$rc" = "$want" ] || {
            printf 'xvb self-test: gate wait — %s: rc=%s want %s (%s)\n' "$label" "$rc" "$want" "$out" >&2
            f=$((f + 1))
        }
    done <<'CASES'
released|true|0|released with the proxy up from the start
held held released|false true|0|released one poll after the caller arrived (the restore race itself)
released held released held|true|1|a release that flickers never holds for two samples
released|true false true false|1|a proxy that keeps dropping never runs for two samples
held marker|true|1|a sync-gate-reset marker keeps the gate held
held|false|1|a gate that never releases times out
CASES
    out="$(XVBT_GATE=held XVBT_PROXY=false && rm -f "$dir/g" "$dir/p" && _xvb_wait_for_gate_release)"
    [ "$out" = "gate=held proxy-running=false" ] || {
        printf 'xvb self-test: the timed-out gate wait did not name its last sample (%s)\n' "$out" >&2
        f=$((f + 1))
    }
    [ ! -e "$dir/touched" ] || {
        printf 'xvb self-test: the gate wait started or stopped a container the gate owns\n' >&2
        f=$((f + 1))
    }
    unset -f sleep _xvb_next _xvb_guest_python _ssh
    eval "$saved"
    rm -rf "$dir"
    _xvb_gate_order_self_test || f=$((f + 1))
    _xvb_gate_payload_self_test || f=$((f + 1))
    [ "$f" -eq 0 ]
}
