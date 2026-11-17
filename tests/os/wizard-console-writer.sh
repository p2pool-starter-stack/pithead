#!/usr/bin/env bash
set -euo pipefail
trap '' HUP
cd /data/pithead
# shellcheck source=pithead
source ./pithead
mode=${1:?}
work=/run/pithead-console-race
trap 'rm -f "$work/ready" "$work/release" "$work/control.issue"' EXIT
if [ "$mode" = control ]; then
    wizard_issue_file() { printf '%s/control.issue' "$work"; }
fi
token=$(journalctl -b -u pithead-setup-again.service -o cat --no-pager | grep -oE 'One-time token: pit-[A-Z0-9]{6}' | tail -1 | cut -d' ' -f3)
[ -n "$token" ]
cert_fp=""
if [ -f data/firstboot/wizard.crt ]; then
    cert_fp=$(openssl x509 -in data/firstboot/wizard.crt -noout -fingerprint -sha256 | cut -d= -f2)
fi
cat() {
    if [ "${1:-}" = "$(wizard_issue_file)" ] && [ ! -e "$work/ready" ]; then
        printf '\n'
        touch "$work/ready"
        local n=0
        while [ ! -e "$work/release" ] && [ "$n" -lt 120 ]; do
            sleep 1
            n=$((n + 1))
        done
        [ -e "$work/release" ] || return 1
    fi
    command cat "$@"
}
wizard_announce_setup "$(wizard_host_addresses || true)" "$token" "$cert_fp"
