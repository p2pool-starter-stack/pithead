#!/usr/bin/env bash
set -uo pipefail
echo "== selftest: owned ENOSPC mount cleanup =="
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
source "$ROOT/lib.sh"
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-faults.sh
source "${ENOSPC_FAULT_MODULE:-$ROOT/lib/run-faults.sh}"
FAKE=$(mktemp -d)
trap 'rm -rf "$FAKE"' EXIT
export FAKE
mkdir -p "$FAKE/bin" "$FAKE/data dir"
python_bin=$(command -v python3)
{
    echo 'REAL_USER=fixture'
    sed -n '/^_data_dir_is_broad_root() {/,/^}/p' "$ROOT/../../lib/pithead/19-small-utilities.sh"
    echo 'apply_tor_egress_firewall() { echo firewall-restored >> "$FAKE/calls"; }'
} >"$FAKE/pithead"
cat >"$FAKE/bin/tool" <<'PY'
#!/usr/bin/python3
import errno
import json
import os
import signal
import sys
from pathlib import Path

root = Path(os.environ['FAKE'])
state_file = root / 'state'
state = json.loads(state_file.read_text())
name = Path(sys.argv[0]).name
args = sys.argv[1:]
mode = os.environ.get('CASE', '')
with (root / 'calls').open('a') as f:
    f.write(name + ' ' + ' '.join(args) + '\n')
def save():
    state_file.write_text(json.dumps(state))
if name == 'cat':
    if args == ['/proc/sys/kernel/random/uuid']:
        print('11111111-2222-3333-4444-555555555555')
    else:
        os.execv('/bin/cat', ['/bin/cat'] + args)
elif name == 'timeout':
    os.execvp(args[3], args[3:])
elif name == 'sudo':
    if args[0] == '-n':
        args.pop(0)
    os.execvp(args[0], args)
elif name == 'realpath':
    print({'root-target': '/', 'broad-target': '/var/lib', 'home-target': '/home/fixture'}.get(mode, args[-1]))
elif name == 'findmnt':
    if mode == 'unreadable-baseline' and not state['mounts']:
        sys.exit(1)
    row = state['mounts'][-1] if state['mounts'] else '10 /dev/data ext4'
    mount_id, source, fstype = row.split()
    target = str(root / 'data dir')
    if mode == 'wrong-target' and state['mounts']:
        target += '/foreign'
    print(json.dumps({'filesystems': [{'id': int(mount_id), 'source': source, 'fstype': fstype, 'target': target}]}))
elif name == 'mount':
    if mode == 'mount-failed':
        sys.exit(1)
    source = args[-2]
    if mode == 'foreign':
        source = 'foreign-tmpfs'
    state['mounts'].append('20 ' + source + ' tmpfs')
    save()
    if mode == 'mount-TERM':
        os.kill(os.getppid(), signal.SIGTERM)
    if mode == 'mount-ambiguous':
        sys.exit(1)
elif name == 'umount':
    if mode == 'cleanup-failed':
        sys.exit(1)
    if state['mounts']:
        state['mounts'].pop()
    else:
        state['underlying'] = False
    if mode == 'baseline-changed':
        state['mounts'].append('30 /dev/foreign ext4')
    save()
elif name == 'python3':
    script = sys.stdin.read()
    real_write = os.write
    def write(fd, data):
        if mode == 'fill-failed':
            raise OSError(errno.EACCES, 'denied')
        if mode != 'fill-no-enospc':
            raise OSError(errno.ENOSPC, 'full')
        return real_write(fd, data)
    os.write = write
    sys.argv = ['-', args[-1]]
    exec(compile(script, '<fill>', 'exec'))
elif name == 'docker':
    if args[0] == 'inspect':
        if mode == 'inspect-failed':
            sys.exit(1)
        source = str(root / ('other' if mode == 'wrong-bind' else 'data dir'))
        print(json.dumps([{'Type': 'bind', 'Destination': '/data', 'Source': source}]))
        sys.exit(0)
    if args != ['compose', 'restart', 'dashboard']:
        sys.exit(0)
    if mode == 'changed-id' and state['mounts']:
        state['mounts'][-1] = state['mounts'][-1].replace('20 ', '21 ', 1)
    state['restarts'] += 1
    save()
    if mode in ('TERM', 'HUP', 'INT') and state['restarts'] == 1:
        os.kill(os.getppid(), getattr(signal, 'SIG' + mode))
    if mode == 'restart-failed' and state['restarts'] == 1:
        sys.exit(1)
    if mode == 'recovery-failed' and state['restarts'] == 2:
        sys.exit(1)
elif name == 'curl':
    value = not bool(state['mounts'])
    if mode == 'unhealthy-missing' and not value:
        sys.exit(1)
    print(json.dumps({'db_healthy': value}))
elif name == 'dd':
    sys.exit(1)
elif name in ('sleep', 'chmod'):
    pass
else:
    raise SystemExit('unexpected tool: ' + name)
PY
chmod +x "$FAKE/bin/tool"
for tool in cat timeout sudo realpath findmnt mount umount python3 docker curl sleep dd chmod; do
    ln -s tool "$FAKE/bin/$tool"
done
export PATH="$FAKE/bin:$PATH"

reset_case() {
    export CASE=$1
    printf '%s\n' '{"mounts":[],"underlying":true,"restarts":0}' >"$FAKE/state"
    : >"$FAKE/calls"
    rm -f "$FAKE/data dir/.itest-fill"
}
state_value() { "$python_bin" -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$FAKE/state" "$1"; }
env_on_box() { case "$1" in COMPOSE_PROFILES) echo local_node ;; *) echo "$FAKE/data dir" ;; esac }
export IT_MODE=local
export IT_REMOTE_DIR="$FAKE"
wait_for() { return 0; }
wait_status_ok() { return 0; }
has_compose_profile() { return 0; }
capture_artifacts() { :; }
fault_rules_clear_all() { :; }
for leg in $(declare -F | awk '$3 ~ /^fault_/ && $3 != "fault_disk_enospc" && $3 !~ /^fault_rules_/ {print $3}'); do
    eval "$leg() { :; }"
done

for test_case in normal root-target broad-target home-target inspect-failed wrong-bind mount-failed foreign wrong-target cleanup-failed mount-ambiguous mount-TERM changed-id baseline-changed fill-failed fill-no-enospc restart-failed recovery-failed unhealthy-missing unreadable-baseline TERM HUP INT; do
    reset_case "$test_case"
    (fault_disk_enospc) >"$FAKE/out" 2>&1
    rc=$?
    if [ "$test_case" = normal ]; then
        assert_eq "normal lifecycle succeeds" "$rc" 0
    else
        assert_ne "$test_case fails the lifecycle" "$rc" 0
    fi
    assert_eq "$test_case preserves underlying storage" "$(state_value underlying)" True
    unmounts=$(grep -c '^umount ' "$FAKE/calls" || true)
    case "$test_case" in
    root-target | broad-target | home-target | inspect-failed | wrong-bind | foreign | wrong-target | changed-id | mount-failed | unreadable-baseline)
        assert_eq "$test_case never unmounts" "$unmounts" 0
        ;;
    *) assert_eq "$test_case unmounts only once" "$unmounts" 1 ;;
    esac
    case "$test_case" in
    foreign | wrong-target | cleanup-failed | baseline-changed)
        assert_eq "$test_case does not restart on unverified storage" "$(state_value restarts)" "$([[ "$test_case" = foreign || "$test_case" = wrong-target ]] && echo 0 || echo 1)"
        ;;
    mount-TERM | TERM | HUP | INT)
        grep -Fxq 'ENOSPC dashboard recovered' "$FAKE/out"
        assert_rc "$test_case records dashboard recovery" "$?" 0
        assert_eq "$test_case removes the temporary mount" "$(state_value mounts)" '[]'
        ;;
    esac
done

(
    rx() { printf '%s\n' 'ENOSPC mount restored' 'ENOSPC dashboard recovered'; }
    fault_disk_enospc
) >"$FAKE/missing-proof.out" 2>&1
assert_ne "zero transport exit cannot hide missing fault proof" "$?" 0

reset_case normal
(run_fault_injection) >"$FAKE/phase.out" 2>&1
assert_eq "phase removes the test mount once" "$(grep -c '^umount ' "$FAKE/calls")" 1
assert_eq "phase preserves underlying data mount after normal recovery" "$(state_value underlying)" True
reset_case mount-failed
(run_fault_injection) >"$FAKE/phase.out" 2>&1
assert_eq "phase never unmounts after mount refusal" "$(grep -c '^umount ' "$FAKE/calls" || true)" 0
assert_eq "phase preserves data mount after mount refusal" "$(state_value underlying)" True
reset_case cleanup-failed
(run_fault_injection) >"$FAKE/phase.out" 2>&1
assert_eq "unsafe phase stops with failure" "$?" 1
assert_eq "unsafe phase does not restart dashboard after cleanup failed" "$(state_value restarts)" 1
assert_eq "unsafe phase still restores the host firewall" "$(grep -c '^firewall-restored$' "$FAKE/calls" || true)" 1

gate=$(sed -n '/^    if \[ "$rig_control_ok" = 1 \] && \[ "$RUN_FAULTS" = "1" \]; then$/,/^    fi # fault-injection gate$/p' "$ROOT/run.sh")
[ -n "$gate" ] || exit 1
(
    export rig_control_ok=1 RUN_FAULTS=1 lifecycle_ok=1 LIFECYCLE_STACK_INTACT=0
    SAFETY_RESTORE_FAILED=0
    run_fault_injection() { return 1; }
    summary() { printf 'restore_failed=%s\n' "$SAFETY_RESTORE_FAILED"; }
    run_gate() {
        eval "$gate"
        echo unsafe-continuation
    }
    run_gate
) >"$FAKE/gate.out" 2>&1
assert_eq "unverified ENOSPC storage stops the runner" "$?" 1
assert_contains "unverified storage disables EXIT backup restore" "$(cat "$FAKE/gate.out")" 'restore_failed=1'
assert_eq "later phases cannot run on unverified storage" "$(grep -c '^unsafe-continuation$' "$FAKE/gate.out" || true)" 0
printf '%s passed / %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" = 0 ]
