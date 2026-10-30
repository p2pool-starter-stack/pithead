#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:?}}"
echo "== chain directory move preservation controls =="
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:?}/chain-move-selftest.XXXXXX")
trap 'find "$work" -depth -delete' EXIT
mkdir -p "$work/install/build/tari" "$work/bin" "$work/data"
for file in docker-compose.yml config.reference.json config.core-keys.json VERSION .env; do
    : >"$work/install/$file"
done
printf '{}\n' >"$work/install/config.json"
cat >"$work/install/pithead" <<'CLI'
#!/usr/bin/env bash
env_get() { printf '%s/%s' "$FIXTURE_ROOT/data" "$1"; }
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return; fi
if [ "${1:-}" = up ]; then
    if [ -f "$FIXTURE_ROOT/install/dashboard/Dockerfile" ]; then
        cmp "$FIXTURE_ROOT/install/dashboard/Dockerfile" dashboard/Dockerfile || exit 10
        cmp "$FIXTURE_ROOT/install/dashboard/source-input" dashboard/source-input || exit 11
    elif [ -f dashboard/Dockerfile ]; then
        exit 12
    fi
fi
if [ "${1:-}" = render ] && [ "${PITHEAD_STEAL_CONTROL_UNITS:-0}" != 1 ]; then exit 8; fi
if [ "${1:-}" = render ] && [ "${FAIL_RESTORE:-0}" = 1 ] && [ "$PWD" = "$(cd "$FIXTURE_ROOT/install" && pwd -P)" ]; then exit 9; fi
CLI
chmod +x "$work/install/pithead"
cat >"$work/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -eu
if [ "$1" = inspect ]; then
    count=$(cat "$FIXTURE_ROOT/count" 2>/dev/null || printf 0)
    count=$((count + 1))
    printf '%s' "$count" >"$FIXTURE_ROOT/count"
    id=monero
    if [ "${CHANGE_ID:-0}" = 1 ] && [ "$count" -gt 1 ]; then id=changed; fi
    printf '[{"Id":"%s","State":{"StartedAt":"start","Running":true}},{"Id":"tari","State":{"StartedAt":"start","Running":true}}]\n' "$id"
else
    printf '{"services":{"monerod":{"volumes":[{"type":"bind","source":"/stable/monero"}]},"tari":{"volumes":[{"type":"bind","source":"/stable/tari"}]}}}\n'
fi
DOCKER
chmod +x "$work/bin/docker"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/sleep"
chmod +x "$work/bin/sleep"
export FIXTURE_ROOT="$work" PATH="$work/bin:$PATH" TMPDIR="$work"
(cd "$work/install" && bash "$root/tests/integration/chain-directory-move.sh") >"$work/pass.log" 2>&1
[ "$(cat "$work/count")" -ge 8 ]
rm "$work/count"
mkdir "$work/install/dashboard"
printf 'FROM scratch\n' >"$work/install/dashboard/Dockerfile"
printf 'source context\n' >"$work/install/dashboard/source-input"
(cd "$work/install" && bash "$root/tests/integration/chain-directory-move.sh") >"$work/source.log" 2>&1 || {
    cat "$work/source.log"
    exit 1
}
[ "$(cat "$work/count")" -ge 8 ]
rm -r "$work/install/dashboard"
rm "$work/count"
if (cd "$work/install" && CHANGE_ID=1 bash "$root/tests/integration/chain-directory-move.sh") >"$work/change.log" 2>&1; then
    printf '%s\n' 'FAIL: changed identity passed'
    exit 1
fi
grep -Fq 'identity or start time changed' "$work/change.log"
rm "$work/count"
if (cd "$work/install" && FAIL_RESTORE=1 bash "$root/tests/integration/chain-directory-move.sh") >"$work/restore.log" 2>&1; then
    printf '%s\n' 'FAIL: failed restoration passed'
    exit 1
fi
grep -Fq 'restoration failed' "$work/restore.log"
printf '%s\n' 'chain directory move selftest: PASS (source and release preservation, changed identity, failed restoration)'
echo "== hardening streams the move proof and requires its completion sentinel =="
source "$root/tests/integration/lib.sh"
source "$root/tests/integration/scenarios.sh"
# shellcheck disable=SC2034
INTEGRATION_RUN_SUITE=1 HERE="$root/tests/integration"
source "$HERE/lib/run-hardening.sh"
eval "$(sed -n '/^run_hardening() {/,/^    local svc probe_out/p' "$HERE/lib/run-hardening.sh" | sed '$d')
}"
IT_MODE=ssh IT_REMOTE_DIR="$work/install" IT_SSH_DEST=fixture
IT_SSH_OPTS=()
run_tari_off_preview() { :; }
env_on_box() { printf local_node; }
ssh() {
    local arg last="" discard=0
    for arg in "$@"; do
        [ "$arg" != -n ] || discard=1
        last="$arg"
    done
    if [ "$discard" = 1 ]; then bash -c "$last" </dev/null; else bash -c "$last"; fi
}
rm -f "$work/count"
run_hardening >"$work/remote.log" 2>&1 || {
    cat "$work/remote.log"
    exit 1
}
if [ "$IT_PASS" != 1 ] || [ "$IT_FAIL" != 0 ] || [ "$(cat "$work/count" 2>/dev/null || echo 0)" -lt 8 ]; then
    cat "$work/remote.log"
    exit 1
fi
ssh() { cat >/dev/null; }
IT_PASS=0 IT_FAIL=0
run_hardening >"$work/empty.log" 2>&1
[ "$IT_PASS" = 0 ] && [ "$IT_FAIL" = 1 ]
printf '%s\n' 'hardening move transport selftest: PASS'
