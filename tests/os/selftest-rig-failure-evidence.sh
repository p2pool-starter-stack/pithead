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
ok() { echo "ok: $*" >>"$work/rows"; }
bad() { echo "bad: $*" >>"$work/rows"; }
full=$'-- coordinator journal from the backup apply --\nj\n-- xmrig-proxy container log --\nx\n-- p2pool container log --\np\n-- proxy summary --\n{"hashrate": {}, "results": {}}\n-- containers --\nxmrig-proxy Up 3 minutes'
_ssh() { printf '%s\n' "$full"; }
rig_failure_evidence_probe
grep -q '^ok: ' "$work/rows"
: >"$work/rows"
full=${full/'-- p2pool container log --'/}
rig_failure_evidence_probe
grep -q '^bad: ' "$work/rows"
: >"$work/rows"
full=${full/'{"hashrate": {}, "results": {}}'/'Traceback: refused'}
_ssh() { printf '%s\n' "$full" '-- p2pool container log --'; }
rig_failure_evidence_probe
grep -q '^bad: ' "$work/rows"
printf 'selftest-rig-failure-evidence: PASS\n'
