#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/rig-failure-evidence.sh
source "$SCRIPT_DIR/rig-failure-evidence.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
_ssh() {
    printf '%s\n' "$1" >"$work/script"
    echo "journal line from --rpc-login leguser:legsecretpass9"
}
out=$(rig_failure_evidence)
for want in 'backup-start-at' 'journalctl --no-pager --since' 'xmrig-proxy p2pool' 'podman logs' '/1/summary' 'podman ps -a'; do
    grep -Fq -- "$want" "$work/script"
done
grep -Fq 'journal line from' <<<"$out"
if grep -Fq 'legsecretpass9' <<<"$out"; then
    echo "secret not redacted" >&2
    exit 1
fi
_ssh() { return 255; }
rig_failure_evidence >/dev/null
printf 'selftest-rig-failure-evidence: PASS\n'
