#!/usr/bin/env bash
set -euo pipefail
echo "== lifecycle mining diagnostic names the proxy exit code and last log lines =="
INTEGRATION_RUN_SUITE=1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=tests/integration/lib/run-lifecycle-miners.sh
source "$ROOT/tests/integration/lib/run-lifecycle-miners.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/lifecycle-proxy-exit.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat >"$work/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift 2
exec "$@"
EOF
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
inspect) case "$*" in *State.ExitCode*State.OOMKilled*) printf 'proxy status=exited exit=137 oom_killed=true\n' ;; esac ;;
logs) printf 'proxy fatal: listener lost\n' ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/systemctl"
chmod +x "$work/bin/"*
rx() { PATH="$work/bin:$PATH" bash -c "$1"; }
LIFECYCLE_MINER_DIAGNOSTICS="$work/diagnostics.log"
lifecycle_mining_diagnostics "restart precondition"
grep -Fq 'exit=137 oom_killed=true' "$work/diagnostics.log"
grep -Fq 'proxy fatal: listener lost' "$work/diagnostics.log"
printf '%s\n' 'PASS: the diagnostic block carries the proxy exit code, OOM flag and last log lines'
