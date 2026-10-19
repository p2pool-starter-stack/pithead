#!/usr/bin/env bash
# Exercise the target probe with fake Docker/API, including failure and signal cleanup.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-pool-sync-fault.sh
source "$HERE/../lib/run-pool-sync-fault.sh"
td=$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:?}}/selftest-p2pool-sync.XXXXXX")
trap 'rm -rf -- "$td"' EXIT
mkdir "$td/bin"
p2pool_sidechain_sync_snippet >"$td/probe.sh"
cat >"$td/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    'compose stop p2pool')
        rm "$STATE/running"
        [ "$CASE" != stop-fails ] || exit 1
        if [ "$CASE" = interrupted ]; then kill -TERM "$PPID"; fi ;;
    'compose start p2pool') touch "$STATE/running" ;;
    'compose ps --services --status running') [ ! -f "$STATE/running" ] || echo p2pool ;;
    *) exit 1 ;;
esac
DOCKER
cat >"$td/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
set -euo pipefail
shift # -n; everything following runs only inside this fixture's scratch directory.
if [ "$1" = cp ]; then
    [ ! -f "$STATE/running" ] || exit 1 # Both backup and restore must precede restart.
    if [ "$CASE" = backup-fails ] && [ "${5##*/}" = original ]; then exit 1; fi
    if [ "$CASE" = restore-fails ] && [ "${4##*/}" = original ]; then exit 1; fi
fi
exec "$@"
SUDO
cat >"$td/bin/date" <<'DATE'
#!/usr/bin/env bash
set -euo pipefail
n=$(cat "$STATE/clock")
echo "$n"
echo "$((n + 30))" >"$STATE/clock"
DATE
cat >"$td/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
exit 0
SLEEP
cat >"$td/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
[ ! -f "$STATE/running" ] || exit 1
case "${*: -1}" in
    */overview.mjs)
        [ "$4" = -o ]
        if [ "$CASE" = missing-module ]; then
            echo unrelated >"$5"
        else
            echo 'P2Pool is syncing its sidechain' >"$5"
            for ((i=0; i<1000; i++)); do echo 'padding ensures the served module is fully downloaded'; done >>"$5"
        fi ;;
    */api/state)
        if [ "$CASE" = transient ] && [ ! -f "$STATE/first-api" ]; then touch "$STATE/first-api"; exit 1; fi
        height=$(jq -r '.pool_statistics.sidechainHeight' "$STATE/data dir/stats/pool/stats")
        syncing=false
        [ "$height" != 3 ] || syncing=true
        [ "$CASE" != pre-fix ] || syncing=false
        [ "$CASE" != sticky ] || syncing=true
        if [ "$CASE" = missing-flag ]; then
            printf '{"pool":{"sidechain_height":%s}}\n' "$height"
        else
            printf '{"pool":{"syncing":%s,"sidechain_height":%s}}\n' "$syncing" "$height"
        fi
        if [ "$CASE" = raw-drift ]; then
            echo '{"pool_statistics":{"sidechainHeight":4}}' >"$STATE/data dir/stats/pool/stats"
        fi ;;
    *) exit 1 ;;
esac
CURL
chmod +x "$td/bin/"*
echo "== P2Pool syncing fault detects bootstrap and restores every return path =="
for CASE in success transient pre-fix missing-flag sticky raw-drift missing-module stop-fails backup-fails restore-fails interrupted; do
    export CASE STATE="$td/$CASE"
    mkdir -p "$STATE/data dir/stats/pool" "$STATE/scratch"
    echo 0 >"$STATE/clock"
    touch "$STATE/running"
    # A different, real-looking file must come back byte-for-byte, with its mode preserved.
    echo '{"pool_statistics":{"hashRate":9000000,"sidechainHeight":14000000}}' >"$STATE/original"
    cp "$STATE/original" "$STATE/data dir/stats/pool/stats"
    chmod 600 "$STATE/data dir/stats/pool/stats"
    rc=0
    PATH="$td/bin:$PATH" TMPDIR="$STATE/scratch" bash "$td/probe.sh" "$STATE/data dir" >"$STATE/log" 2>&1 || rc=$?
    [ -f "$STATE/running" ] # Every return path must start the writer again.
    if [ "$CASE" = restore-fails ]; then
        [ "$rc" -ne 0 ]
        [ -n "$(ls -A "$STATE/scratch")" ] # Keep a failed restore's backup.
        ! grep -q 'original stats restored' "$STATE/log"
        continue
    fi
    cmp -s "$STATE/original" "$STATE/data dir/stats/pool/stats"
    [ "$(stat -c %a "$STATE/data dir/stats/pool/stats")" = 600 ]
    [ -z "$(ls -A "$STATE/scratch")" ]
    if [ "$CASE" = success ] || [ "$CASE" = transient ]; then
        [ "$rc" -eq 0 ]
        grep -Fxq 'p2pool-sync: bootstrap syncing=true with raw height 3' "$STATE/log"
        grep -Fxq 'p2pool-sync: served overview contains sidechain sync message' "$STATE/log"
        grep -Fxq 'p2pool-sync: synced stats clear syncing=false' "$STATE/log"
    else
        [ "$rc" -ne 0 ]
    fi
done
echo 'selftest-p2pool-sync-fault: 11 cases passed (positive, pre-fix, recovery, missing evidence, raw drift, preparation, restoration, signal)'

# Diagnostics from a failed target must be redacted before an assertion can print them.
echo "== P2Pool syncing fault redacts failed target diagnostics before assertions =="
OUT_DIR="$td"
env_on_box() { printf '%s' "$td/data dir"; }
quote_arg() { printf '%q' "$1"; }
it_step() { :; }
rx() {
    cat >/dev/null
    echo secret-diagnostic
    return 1
}
redact() { sed 's/secret-diagnostic/REDACTED/g'; }
assert_rc() { [ "$2" = 1 ]; }
assert_contains() { [ "$2" = REDACTED ]; }
fault_p2pool_sidechain_sync
grep -Fxq REDACTED "$OUT_DIR/p2pool-sidechain-sync.log"
echo 'selftest-p2pool-sync-fault: failed target diagnostics redacted before assertions'
