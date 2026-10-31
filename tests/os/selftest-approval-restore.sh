#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/appliance-config-approval-leg.sh
source "$HERE/appliance-config-approval-leg.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
guest="$work/guest"
calls="$work/calls"
evidence="$work/evidence"
SSH_ERR="$work/ssh-error"
snapshot="$guest/data/control/.os1966-original-config.json"
scenario=success
mkdir -p "$guest/data/control"
cat >"$guest/pithead" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$*" = 'apply -y' ]
printf 'configuration applied\n'
if [ "$SCENARIO" = mismatch ]; then
    printf 'changed during apply\n' > config.json
fi
SH
chmod +x "$guest/pithead"

reset_fixture() {
    printf 'original config\n' >"$snapshot"
    printf 'changed config\n' >"$guest/config.json"
    : >"$calls"
    : >"$SSH_ERR"
    : >"$evidence"
    APPROVAL_RESTORE_SNAPSHOT="$snapshot"
}

_control_requests_drained() {
    printf 'drain\n' >>"$calls"
    if [ "$scenario" = drain ]; then
        printf 'control spool still holds 2 in-flight request(s) after the drain deadline\n'
        return 31
    fi
}

_ssh() {
    local operation command="$1"
    case "$command" in
    install*) operation=install ;;
    *'./pithead apply'*) operation=apply ;;
    cmp*) operation=compare ;;
    rm*) operation=remove ;;
    *) return 99 ;;
    esac
    printf '%s\n' "$operation" >>"$calls"
    : >"$SSH_ERR"
    if [ "$scenario" = "$operation" ]; then
        printf 'No space left on device: fake-private-host fake-password\n'
        printf 'Permission denied: /home/fake-user/private 192.0.2.16\n' >"$SSH_ERR"
        return 32
    fi
    command=${command//\/data\/pithead/"$guest"}
    SCENARIO="$scenario" bash -c "$command" 2>"$SSH_ERR"
}

for scenario in drain install apply compare remove; do
    reset_fixture
    rc=0
    approval_restore_pending >"$evidence" 2>&1 || rc=$?
    expected_rc=32
    [ "$scenario" != drain ] || expected_rc=31
    [ "$rc" -eq "$expected_rc" ]
    grep -Fq "operation=$scenario exit=$expected_rc" "$evidence"
    [ "$APPROVAL_RESTORE_SNAPSHOT" = "$snapshot" ]
    [ -f "$snapshot" ]
    [ "$(tail -1 "$calls")" = "$scenario" ]
    if [ "$scenario" != drain ]; then
        grep -Fq 'no space left on device' "$evidence"
        grep -Fq 'permission denied' "$evidence"
    fi
    ! grep -Eq 'fake-private-host|fake-password|fake-user|192\.0\.2\.16|/home/' "$evidence"
done

scenario=mismatch
reset_fixture
rc=0
approval_restore_pending >"$evidence" 2>&1 || rc=$?
[ "$rc" -eq 1 ]
grep -Fq 'operation=compare exit=1' "$evidence"
[ -f "$snapshot" ]
[ "$APPROVAL_RESTORE_SNAPSHOT" = "$snapshot" ]
[ "$(tail -1 "$calls")" = compare ]

scenario=apply
reset_fixture
rc=0
approval_restore_pending >>"$evidence" 2>&1 || rc=$?
[ "$rc" -eq 32 ]
scenario=install
rc=0
approval_fixture_cleanup >>"$evidence" 2>&1 || rc=$?
[ "$rc" -eq 1 ]
grep -Fq 'operation=apply exit=32' "$evidence"
grep -Fq 'operation=install exit=32' "$evidence"
grep -Fq 'approval cleanup FAILED' "$evidence"
[ -f "$snapshot" ]

scenario=success
reset_fixture
python3() {
    cat >/dev/null
    return 37
}
rc=0
approval_restore_pending >"$evidence" 2>&1 || rc=$?
unset -f python3
[ "$rc" -eq 1 ]
grep -Fq 'operation=drain diagnostic-filter-failed' "$evidence"
[ "$APPROVAL_RESTORE_SNAPSHOT" = "$snapshot" ]
[ -f "$snapshot" ]
[ "$(cat "$calls")" = drain ]

reset_fixture
approval_restore_pending >"$evidence" 2>&1
[ -z "$APPROVAL_RESTORE_SNAPSHOT" ]
[ ! -e "$snapshot" ]
[ "$(cat "$guest/config.json")" = 'original config' ]
[ "$(tr '\n' ' ' <"$calls")" = 'drain install apply compare remove ' ]
for operation in drain install apply compare remove; do
    grep -Fq "operation=$operation exit=0" "$evidence"
done
reset_fixture
approval_fixture_cleanup
[ -z "$APPROVAL_RESTORE_SNAPSHOT" ]
[ ! -e "$snapshot" ]
: >"$calls"
approval_restore_pending
[ ! -s "$calls" ]

python3 - "$HERE/approval-restore-output.py" <<'PY'
import subprocess
import sys

payload = (
    b"\x1b[31mPermission denied\x1b[0m: secret.example /home/private token=hidden\n"
    b"No space left on device 192.0.2.16 wallet=hidden\n"
    + b"a" * 100000
    + b"\n"
) * 10
result = subprocess.run(
    [sys.executable, sys.argv[1]], input=payload, capture_output=True, check=True
)
assert b"permission denied" in result.stdout
assert b"no space left on device" in result.stdout
assert b"additional output omitted" in result.stdout
assert len(result.stdout) < 3500
assert len(result.stdout.splitlines()) <= 14
for value in (b"secret.example", b"/home/", b"hidden", b"192.0.2.16", b"\x1b"):
    assert value not in result.stdout
late = subprocess.run(
    [sys.executable, sys.argv[1]],
    input=b"progress\n" * 10000 + b"Permission denied\n",
    capture_output=True,
    check=True,
)
assert b"permission denied" in late.stdout
PY
printf 'approval-restore: PASS\n'
