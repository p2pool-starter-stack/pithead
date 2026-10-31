#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
echo "== cancellation finishes deploy before restoring once =="
python3 - <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def function(text, name):
    start = text.index(name + '() {')
    return text[start:text.index('\n}', start) + 2]


def release(root, name, process):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            fd = os.open(root / name, os.O_WRONLY | os.O_NONBLOCK)
        except OSError:
            assert process.poll() is None, 'exited before release'
            time.sleep(0.01)
        else:
            os.write(fd, b'release')
            os.close(fd)
            return
    raise AssertionError('timed out releasing ' + name)


def wait_for(events, marker, process):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if marker in events.read_text().splitlines():
            return
        if process.poll() is not None:
            raise AssertionError(f'exited {process.returncode} before {marker}')
        time.sleep(0.01)
    raise AssertionError(f'timed out before {marker}')


e2e = Path('tests/integration/e2e.sh').read_text()
chain = Path('tests/integration/lib/chain-keep.sh').read_text()
traps = '\n'.join(line for line in e2e.splitlines() if line.startswith('trap '))
for transport in ('local', 'ssh'):
    for cancelled, deploy_rc in ((False, 0), (False, 23), (True, 0), (True, 23)):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            events = root / 'events'
            events.touch()
            for name in ('deploy-release', 'restore-release'):
                os.mkfifo(root / name)
            pithead = root / 'pithead'
            pithead.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
root = Path(os.environ['CASE_ROOT'])
with (root / 'events').open('a') as stream:
    stream.write('deploy-ready\\n')
with (root / 'deploy-release').open() as stream:
    stream.read()
with (root / 'events').open('a') as stream:
    stream.write('deploy-done\\n')
raise SystemExit(int(os.environ['DEPLOY_RC']))
''')
            pithead.chmod(0o755)
            docker = root / 'docker'
            docker.write_text('#!/usr/bin/env bash\nexit 0\n')
            docker.chmod(0o755)
            ssh = root / 'ssh'
            ssh.write_text('#!/usr/bin/env bash\nprintf "ssh\\n" >>"$CASE_ROOT/events"\nexec bash -c "${!#}"\n')
            ssh.chmod(0o755)
            driver = root / 'driver.sh'
            driver.write_text('''set -euo pipefail
source tests/integration/lib/parent-lock.sh
SSH_OPTS=()
BENCH_HOST=fixture
RIG_LOCK_PARENT_ACTOR=''
if [ "$TRANSPORT" = local ]; then
    BENCH_HOST=localhost
    RIG_LOCK_PARENT_ACTOR=fixture
fi
on_bench() { parent_lock_on_bench "$BENCH_HOST" "$@"; }
E2E_DIR="$CASE_ROOT"
CHAIN_SERVICES=''
chain_snapshot() { :; }
parent_lock_checkpoint() { :; }
prepare_rotate_onion_fixture() { :; }
log() { :; }
step() { :; }
ok() { :; }
wait_bench_healthy() { :; }
wait_synced() { :; }
warn() { :; }
die() { exit 1; }
restore_all() {
    printf 'restore-ready\\n' >>"$CASE_ROOT/events"
    cat "$CASE_ROOT/restore-release" >/dev/null
    printf 'restore-done\\n' >>"$CASE_ROOT/events"
}
''' + function(chain, 'deploy_keeping_chain') + '\n' +
                function(e2e, 'deploy_branch') + '\n' + traps + '''
deploy_branch
printf 'continued\\n' >>"$CASE_ROOT/events"
''')
            env = dict(os.environ, CASE_ROOT=tmp, TRANSPORT=transport,
                       DEPLOY_RC=str(deploy_rc), PATH=tmp + ':' + os.environ['PATH'])
            with (root / 'output').open('w+') as output:
                process = subprocess.Popen(['bash', str(driver)], env=env,
                                           stdout=output, stderr=output,
                                           start_new_session=True)
                try:
                    wait_for(events, 'deploy-ready', process)
                    if cancelled:
                        process.send_signal(signal.SIGTERM)
                        time.sleep(0.1)
                        assert 'restore-ready' not in events.read_text(), 'restore overlaps deploy'
                    release(root, 'deploy-release', process)
                    wait_for(events, 'restore-ready', process)
                    if cancelled:
                        process.send_signal(signal.SIGTERM)
                    release(root, 'restore-release', process)
                    rc = process.wait(timeout=8)
                    rows = events.read_text().splitlines()
                    assert rows.index('deploy-done') < rows.index('restore-ready'), rows
                    assert rows.count('restore-ready') == rows.count('restore-done') == 1, rows
                    assert ('ssh' in rows) == (transport == 'ssh'), rows
                    if cancelled:
                        assert rc == 143, (rc, rows)
                        assert 'continued' not in rows, rows
                    elif deploy_rc:
                        assert rc != 0 and 'continued' not in rows, (rc, rows)
                    else:
                        assert rc == 0 and 'continued' in rows, (rc, rows)
                except Exception:
                    output.seek(0)
                    print(output.read())
                    raise
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
            print(f'PASS: {transport} cancel={cancelled} deploy_rc={deploy_rc}')
PY
