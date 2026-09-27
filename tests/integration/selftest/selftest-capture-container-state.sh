#!/usr/bin/env bash
#
# Self-test for the container state in compose-ps.txt (#2562). A scenario failure must keep each
# container's exit code, OOMKilled flag and restart count: compose ps shows `Restarting (137)`,
# which says SIGKILL but not who sent it, so the P2Pool OOM in #2562 had to be inferred.
# Runs the REAL `capture_artifacts` from lib.sh against a fake box in IT_MODE=local.
#
# Run: tests/integration/selftest/selftest-capture-container-state.sh
#
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BOX="$TMP/box"
OUT="$TMP/out"
FAKEBIN="$TMP/bin"
mkdir -p "$BOX" "$OUT" "$FAKEBIN"

# A fake docker: `compose ps -aq` lists one id; `inspect` answers only for that id, the way the
# real daemon would render the --format template for an OOM-killed p2pool.
cat >"$FAKEBIN/docker" <<'EOF'
#!/bin/sh
case "$1 $2 $3" in
"compose ps -aq") echo c0ffee ;;
esac
if [ "$1" = inspect ]; then
    case "$*" in
    *'{{.State.OOMKilled}}'*c0ffee*) echo "/p2pool exit=137 oom_killed=true restarts=4" ;;
    *) exit 1 ;;
    esac
fi
exit 0
EOF
printf '#!/bin/sh\nexit 1\n' >"$FAKEBIN/curl"
chmod +x "$FAKEBIN/docker" "$FAKEBIN/curl"

export PATH="$FAKEBIN:$PATH"
export IT_MODE=local
export IT_REMOTE_DIR="$BOX"
export IT_PITHEAD=true

echo "== capture_artifacts: container exit code, OOMKilled and restarts are kept (#2562) =="

capture_artifacts "state" "$OUT" >/dev/null 2>&1
assert_contains "compose-ps.txt carries the kernel's OOM verdict per container" \
    "$(cat "$OUT/state/compose-ps.txt" 2>/dev/null)" "/p2pool exit=137 oom_killed=true restarts=4"

echo "selftest-capture-container-state: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
