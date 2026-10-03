# shellcheck shell=bash
# Failure evidence for bundle staging (#3049). Sourced by tests/os/run.sh next to failure-evidence.sh.

# staging_failure_evidence <rc> <bundle> (#3049)
# Bundle staging (the scp into /data/update.bundle) failed BEFORE os-update ran, so this is an
# environment or transport fault, not an os-update verdict. rc 124 is the harness's STAGE_TIMEOUT
# kill, 255 is ssh/scp transport death. Every probe is bounded: the guest may be exactly what
# stopped answering. Reads $STAGE_ERR, $SERIAL, $VM and $ip.
staging_failure_evidence() {
    printf '     bundle staging rc=%s (124 = harness timeout kill, 255 = scp transport death) — an environment/transport fault; os-update was NOT invoked\n' "$1"
    printf '     bundle: %s bytes\n' "$(stat -c %s "$2" 2>/dev/null || echo unreadable)"
    printf '     scp client stderr: %s\n' "$(tr -d '\r' <"${STAGE_ERR:-/dev/null}" 2>/dev/null | tail -5 | tr '\n' ';')"
    printf '     domain state: %s\n' "$(timeout 20 virsh domstate "${VM:-}" 2>&1 | tr '\n' ' ')"
    cp -f "$SERIAL" "$SERIAL.failed" 2>/dev/null || true
    printf '     serial tail: %s\n' "$(tail -c 600 "$SERIAL" 2>/dev/null | tr -d '\r' | tr '\n' ';')"
    printf '     --- guest probe (20s bound) ---\n'
    SSH_TIMEOUT=20 _ssh "uptime; df -h /data | tail -1; ls -l /data/update.bundle 2>&1; journalctl -k --no-pager -n 5 2>/dev/null" 2>/dev/null |
        tr -d '\r' | sed 's/^/     · /'
}
