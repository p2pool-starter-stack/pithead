#!/usr/bin/env bash
# Prove launcher-only RigForge inputs are rejected before e2e.sh can call SSH.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
TMP="$(mktemp -d)"
MARKER="$TMP/ssh-called"
trap 'rm -r "$TMP"' EXIT
cat >"$TMP/ssh" <<'SH'
#!/usr/bin/env bash
: >"$SSH_MARKER"
exit 99
SH
chmod +x "$TMP/ssh"

rejected_before_ssh() { # <label> <env-name> <bad-value>
    rm -f "$MARKER"
    env PATH="$TMP:/usr/bin:/bin" SSH_MARKER="$MARKER" BENCH_HOST=bench MINER_HOST=rig \
        "$2=$3" bash "$HERE/../e2e.sh" candidate --mode matrix >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -ne 0 ] && [ ! -e "$MARKER" ]; then
        it_pass "$1"
    else
        it_fail "$1" "rc=$rc ssh_called=$([ -e "$MARKER" ] && echo yes || echo no)"
    fi
}

echo "== e2e rejects launcher injection before SSH =="
rejected_before_ssh "control port metacharacters never reach SSH" RIG_CONTROL_PORT '8082;touch'
rejected_before_ssh "pre-supplied rig NAME metacharacters never reach SSH, even without a token" RIG_NAME 'rig;touch'
rejected_before_ssh "a valid first line cannot hide a second rig NAME line" RIG_NAME $'rig\ninvalid;value'
rejected_before_ssh "bootstrap target metacharacters never reach SSH" RIGFORGE_BOOTSTRAP_VERSION 'v1.17.2;touch'

printf '\npassed: %s, failed: %s\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
