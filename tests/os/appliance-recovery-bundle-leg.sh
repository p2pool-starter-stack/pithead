#!/usr/bin/env bash

recovery_bundle_guest_script() {
    cat <<'GUEST'
set -uo pipefail
cli=/opt/pithead/pithead
unit=
for u in p2pool.service xmrig.service docker-control.service xmrig-proxy.service; do
    if [ "$(systemctl show -p LoadState --value "$u")" = not-found ]; then
        unit=$u
        break
    fi
done
[ -n "$unit" ] || { echo "recovery bundle leg: no unloaded pithead unit name to fault"; exit 1; }
[ -z "$(podman ps -q 2>/dev/null)" ] || { echo "recovery bundle leg: containers are running, the stack is not down"; exit 1; }
systemd-run --quiet --unit="${unit%.service}" --wait -p Type=oneshot sh -c 'echo recovery-leg-marker; exit 3' >/dev/null 2>&1
systemctl is-failed --quiet "$unit" || { echo "recovery bundle leg: $unit did not fail"; exit 1; }
out=$(mktemp)
"$cli" recovery-bundle --hours 1 >"$out" 2>&1
rc=$?
cat "$out" >/dev/ttyS0
arch=$(sed 's/\x1b\[[0-9;]*m//g' "$out" | sed -n 's/.*Support bundle written: //p' | tail -1)
systemctl reset-failed "$unit" 2>/dev/null
[ "$rc" -eq 0 ] || { echo "recovery bundle leg: verb exited $rc"; exit 1; }
case "$arch" in /data/pithead/support-bundles/support-bundle-*.tar.gz) ;; *) echo "recovery bundle leg: unexpected path '$arch'"; exit 1 ;; esac
[ "$(stat -c %a "$arch")" = 600 ] || { echo "recovery bundle leg: archive mode is $(stat -c %a "$arch"), want 600"; exit 1; }
tar -xzOf "$arch" "bundle/logs/$unit.log" | grep -q recovery-leg-marker || { echo "recovery bundle leg: no journal line from failed $unit in the archive"; exit 1; }
rm -f "$arch" "$out"
echo "recovery bundle leg: PASS $arch"
GUEST
}

phase_fault_recovery_bundle() {
    local out rc=0
    out=$(mktemp)
    recovery_bundle_guest_script | base64 | tr -d '\n' >"$out.payload"
    SSH_TIMEOUT=240 _ssh "base64 -d <<<'$(cat "$out.payload")' | bash" >"$out" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] && grep -Fq 'recovery bundle leg: PASS' "$out"; then
        ok "recovery-bundle writes a 600 archive under /data/pithead with the stack down, carrying a failed unit's journal lines (#4038)"
    else
        [ "$rc" -eq 0 ] && rc=1
        bad "recovery-bundle did not produce the expected archive with the stack down (#4038, exit $rc): $(tail -n 3 "$out" | tr '\n' ' ' | cut -c1-300)"
    fi
    if wait_serial 'Support bundle written: /data/pithead/support-bundles/support-bundle-' 30; then
        ok "recovery-bundle prints the archive path where the serial console shows it (#4038)"
    else
        bad "the archive path never reached the serial console (#4038)"
    fi
    rm -f "$out" "$out.payload"
}
