#!/usr/bin/env bash
set -euo pipefail
echo "== lifecycle mining diagnostic names the proxy exit code and last log lines =="
INTEGRATION_RUN_SUITE=1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=tests/integration/lib/run-lifecycle-miners.sh
source "$ROOT/tests/integration/lib/run-lifecycle-miners.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/lifecycle-proxy-exit.XXXXXX")
trap 'rm -rf "$work"' EXIT
rx() { printf '%s\n' "$1" >"$work/snippet"; }
LIFECYCLE_MINER_DIAGNOSTICS="$work/diagnostics.log"
lifecycle_mining_diagnostics "restart precondition"
for needle in 'exit={{.State.ExitCode}}' 'oom_killed={{.State.OOMKilled}}' 'finished={{.State.FinishedAt}}' 'logs --tail 20 xmrig-proxy'; do
    grep -Fq -- "$needle" "$work/snippet" || {
        echo "FAIL: diagnostic command lacks $needle"
        exit 1
    }
done
printf '%s\n' 'PASS: the diagnostic inspects exit code, OOM flag, finish time and tails the proxy log'
