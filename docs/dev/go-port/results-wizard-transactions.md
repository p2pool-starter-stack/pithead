# Wizard transaction parity

This slice ports atomic submission-file writes, unlink-only removal, conflict
checks, rollback and temporary-file cleanup. The original wizard tests and
fixtures remain unchanged. Python still owns auth, form/config validation,
upload decisions and HTTP submission orchestration.

## Native boundary

`go/internal/dashboard/wizard/transactions.go` preserves the transaction file
inventory and operation order from `wizard_transaction.py`. Writes create the
directory, stage a private inode with mode 0600 subject to the caller's umask,
close it and rename it onto the destination. Failure removes the write's own
temporary. Path construction retains Python's absolute-name reset and uncleaned
relative traversal. Removal uses unlink and refuses directories. Conflict detection
preserves archive precedence, orphan-passphrase cleanup and the exact 409/500
JSON errors. Rollback attempts every owned file before sweeping temporaries.

Temporary cleanup only considers the named `.NAME.` prefixes in the two wizard
directories. Regular files and symlinks are removed; directories and other file
types remain and report failure. Directory enumeration uses a directory-only
open, including when an unexpected FIFO occupies the configured path.

`go_wizard_transaction.py` installs these operations on the original transaction
module and the wizard server's captured aliases in Go mode. Reference selection
retains Python. Helper startup, framing or execution failures are fatal; there is
no silent reference fallback. The shared `go_channel.py` decoder preserves the
existing exception mapping and native errno values.
Writer startup, timeout and nonzero-exit errors remain `OSError` so the existing
handlers execute their rollback path after an interrupted write.

Archive writes use a bounded JSON metadata line followed by the exact raw byte
count on stdin. `wizard-write` copies that stream directly into the staged file;
it does not base64-encode the archive or buffer it again in Go. Python still
holds the existing uploaded bytes and one subprocess input copy. No secret is
passed in argv or printed by the adapters. This is a transport bound, not proof
of the dashboard image's memory cap.

The existing wizard launch command and Python handlers remain. Recovery-handler
file removal, auth, config/form shaping, install/node validation, upload policy,
submission sequencing and handoff orchestration have not been reimplemented.
Production container selection and shipping artifacts remain pending.

## Adapters and native proof

All new harness files are under `tests/go-parity/`:

- `dashboard_wizard_transaction_plugin.py` layers over the channel adapter,
  replaces every original ported transaction body with a fatal sentinel and
  records successful native operations and error classes.
- `dashboard_wizard_io.py` handles the original tests' patched `os.replace` and
  `os.unlink`. Go still controls staging, policy, order and cleanup; the adapter
  executes the injected Python syscall and returns its result/errno over a
  private callback protocol. These explicit interpositions do not prove native
  rename/unlink. Production calls have no callbacks and execute Go syscalls.
- `dashboard_wizard_transaction_compare.py` adds eight comparison cases covering
  exact bytes, restrictive umasks, ownership, symlinks, rollback, conflicts,
  fail-closed helpers and an archive at the existing 64 MiB upload limit.
- `dashboard_wizard_transaction_guards.py` compiles isolated source overlays.
  Breaking native writes makes the unchanged volatile-restore upload test fail
  with 500 instead of 200. Returning success without sweeping makes the unchanged
  unsafe-temp startup test fail. Both controls require the expected native-call
  or error counter, as well as the original assertion failure.
- `dashboard_wizard_writer_failures.py` interrupts an authenticated archive write
  with a timeout, nonzero exit or malformed response after creating a hidden
  archive temporary. Each case proves the original handler rolls back all owned
  files, including the volatile passphrase, without returning secret content.

`make test-go-dashboard-wizard-transaction-parity` runs the original wizard files
with this plugin and then thirteen supplementary cases. The earlier port-added
channel target now loads the same plugin, which includes its channel dependency,
so its unchanged fault tests still reach the native transaction boundary. The
bounded Go CI job includes the new target. No pre-port Make target changed.

Go unit tests cover short streams, framing errors, callback errno/cleanup,
unlink-only refusal, file permissions, conflict precedence, exact temp prefixes,
symlink/FIFO safety, path compatibility and aggregate rollback failures.

## Commands and results

Use the worktree-local caches from PARITY.md and the locked Python 3.11
environment. No Docker, live stack or fleet job was used.

```bash
cd dashboard
PITHEAD_IMPL=python .venv/bin/python -m pytest tests/web/test_wizard*.py
```

The same command also runs against an isolated archive of starting commit
`a73ffced33800de9435779a9cabef53864455acb`, using the installed Python interpreter
and the archived package. Supplementary comparison processes run current Python
and Go separately; they are not described as unchanged suites.

| Check | Reference | Go selection |
|---|---|---|
| Original wizard files | 282 passed at the frozen start and current head | 282 passed unchanged through the transaction adapter |
| Focused transaction target | New cases run separate Python reference arms where applicable | `make test-go-dashboard-wizard-transaction-parity`: 295 passed, 282 original plus 13 new |
| Earlier channel target | Prior frozen/current reference: 377 original passed | `make test-go-dashboard-channel-parity`: 403 passed, 377 original plus 26 new |
| Full dashboard | `PITHEAD_IMPL=python make test-dashboard`: 3719 passed, 92.34% Python coverage | Full Go command below: 3719 passed, 84.14% Python coverage |
| Go checks | Python reference retained | Race units, vet, module verification and CGO-free Linux amd64/arm64 command builds passed |
| Patch coverage | Reference-only `make test-patch-coverage`: failed at 55% | Go-only failed at 84%; appended A/B comparisons passed at 95% |
| Full Make | `PITHEAD_IMPL=bash make test`: exit 2 at dependency-cache Markdown | Same Go plugin environment below with `make test`: same exit 2 |

The final focused run recorded 543 complete native writes, 334 removals, 142
conflict checks, 208 temporary sweeps, 95 sidecar cleanups and five complete
rollbacks. Those counts include the supplementary in-process fault cases, not
their isolated child processes. The explicit I/O path reported 22 replace and
69 unlink callbacks. Operations executing while a mock was installed are
reported separately from callbacks actually invoked.

An initial focused run passed 291 cases and failed one newly added missing-helper
message expectation. That expectation was corrected. Independent correctness and
security reviews then found the path-join and writer-rollback gaps described
above; both were corrected and the final 295-case target passed. The reviews
reported no remaining finding.

The full Go dashboard command is:

```bash
PITHEAD_IMPL=go \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin,dashboard_wizard_transaction_plugin \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_XDIST_AUTO_NUM_WORKERS=1 make test-dashboard
```

The full count includes the 3716 original tests and three snapshot cases added
by an earlier port slice. The focused reference uses the same frozen-start test
paths. Python coverage alone does not measure native Go execution.

Full-suite native call counts belong to xdist workers, so no aggregate is
inferred from their parent. The focused target reports native calls and injected
I/O separately. Its source mutations alter only private overlay files and use
isolated coverage output.

The coverage append command was:

```bash
PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" \
make test-go-dashboard-overview-parity test-go-dashboard-fleet-parity \
  test-go-dashboard-http-parity test-go-dashboard-storage-parity \
  test-go-dashboard-channel-parity test-go-dashboard-wizard-transaction-parity
make test-patch-coverage
```

Those targets passed 202, 151, 34, 357, 403 and 295 cases respectively. The gate
measured 37 changed tracked Python files; new untracked files enter the diff
after the operator commits. The appended XML separately measures the new
transaction bridge at 52/52 executable lines. `go_channel.py` and `go_wizard.py`
measure 59/61 and 83/84. The reference XML was retained before the Go run and
graded separately. Existing coverage rules and thresholds remain unchanged.

The final native checks were:

```bash
make go-build go-dashboard-build
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go -C go build -o "../.go-cache/wizard-txn-linux-$arch/" ./cmd/pithead ./cmd/dashboard
done
```

GNU-first topology lint passes, including additive enumeration of untracked
files through the original scanner and allowlists. Generated CLI, file budget,
docs voice, path references, operator strings, YAML, full Ruff lint/format,
changed-document Markdown and diff checks pass. File budget uses the documented
starting-SHA override; no ceiling or rule changed. Comparison against the frozen
start reports no modifications to any original file under either test tree.

Both full Make runs pass shell lint and stop at Markdown in the required local
dependency cache. Docker/image, Linux-only CLI, appliance, privileged and fleet
checks remain unproven; no live stack was touched.

## Remaining work

Finish wizard auth/form/submission and remaining control orchestration, then
production selection and release/dashboard/appliance shipping integration.
The backend remains hybrid: Python polling, business SQL and other unported
handlers still run. Performance work belongs to the separate benchmark session.
