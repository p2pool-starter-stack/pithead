# Native SQLite parity results

The 2026-11-01 storage slice ports the database engine, open, schema, migrations,
integrity checks and corrupt-database recovery. The normal Go dashboard command
installs the native storage bridge before constructing the Python application.
The reference Python launch and all existing tests and fixtures remain unchanged.

## Native scope

`go/internal/dashboard/storage/` owns 15 application tables, ten indexes, all
existing column/data migrations, WAL mode, synchronous mode, busy timeout,
integrity checks, quarantine, sidecar cleanup, retention and recovery health.
Legacy migration failures preserve the reference's implicit transaction boundary:
DDL before the first timestamp update commits independently.

The module pins `modernc.org/sqlite` 1.61.1 and transitive dependencies in
`go/go.mod` and `go/go.sum`. Go 1.26 is the minimum; local and CI tools use Go
1.27.1. Both commands build for Linux amd64 and arm64 with CGO disabled.

`dashboard/mining_dashboard/go_storage.py` provides the connection/cursor bridge
to a Go helper using private JSON lines over stdin/stdout. It preserves SQL
parameters, transactions, integer bounds, binary values, nonfinite float behavior
and error classes used by StateManager. A helper failure marks the manager
unhealthy and closes its resources. Constructor errors, transport failure,
explicit close and garbage collection reap the child process.

Python still owns StateManager memory state, business methods and SQL construction.
Polling, earnings/XvB, wizard/control and unported handlers remain Python. The
bridge is an interim process boundary, not a performance claim or a general SQL
compatibility library. Production container selection and shipping integration
remain pending.

## Adapters

All hooks below are new files under `tests/go-parity/`:

- `dashboard_storage_plugin.py` selects GoStateManager for the unchanged suites.
  Original Python connection, schema, migration and recovery methods become
  fatal. Tests can still use Python SQLite directly to seed or inspect databases.
  Existing mocked schema/reopen failures are translated into explicit private
  helper fault inputs so the same unchanged failure assertions exercise Go.
- `dashboard_storage_startup.py` uses the normal Go command and its Python child
  with a minimal app fixture. Existing, legacy and corrupt database cases compare
  schema, migration, retained data, health and quarantine, then request state and
  miner connection without caller retries. Original Python lifecycle and database
  connection paths are fatal. A missing native bridge fails before app creation
  or any Python database open. Stateless transport fixtures remain supported.
- `dashboard_storage_bridge_compare.py` checks process cleanup, missing helper,
  transport failure, transaction rollback, SQLite error classes, int64 overflow,
  BLOB/nonfinite values, failed reopen/retry and preserved unrecoverable health.

The new Make target runs 343 unchanged storage/worker tests plus four startup
cases and ten bridge cases. The bounded Go CI workflow includes that target.
Existing presentation targets retain their own reference comparison fixtures;
the full Go run below explicitly enables both storage and presentation adapters.

## Commands and results

Commands run at the worktree root with these local cache settings:

```bash
export GOCACHE="$PWD/.go-cache/build" GOMODCACHE="$PWD/.go-cache/mod"
export GOPATH="$PWD/.go-cache/gopath" TMPDIR="$PWD/.go-cache/tmp"
export UV_CACHE_DIR="$PWD/.uv-cache" UV_OFFLINE=1 UV_PYTHON_DOWNLOADS=never
export PYTEST_XDIST_AUTO_NUM_WORKERS=1
```

| Suite | Reference command/result | Go command/result |
|---|---|---|
| Focused unchanged oracle | `cd dashboard && PITHEAD_IMPL=python .venv/bin/python -m pytest -q tests/service/test_storage*.py tests/service/workers/test_worker_*.py`: 343 passed | `make test-go-dashboard-storage-parity`: 357 passed, including 343 unchanged tests and 14 additional cases |
| Full dashboard | `PITHEAD_IMPL=python COVERAGE_FILE="$PWD/.go-cache/coverage-storage-baseline" make test-dashboard`: 3719 passed, 94.53% Python coverage | Full Go command below: 3719 passed, 85.04% Python coverage |
| Units | Reference schema/recovery assertions in the unchanged focused suite | `go -C go test -race -count=1 ./...`: passed; final focused storage units also passed |
| Static checks | Existing checks unchanged | `go -C go vet ./...` and `go -C go mod verify`: passed |
| Commands | Bash/Python retained | `make go-build go-dashboard-build`: passed |
| Linux builds | No runtime Linux verdict | `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go -C go build -o "$PWD/.go-cache/storage-linux-amd64/" ./cmd/...`, repeated with arm64: passed |
| Regression targets | Existing oracles and comparison controls retained | `make test-go-native-guards test-go-parity test-go-dashboard-http-parity test-go-dashboard-state-parity`: passed |
| Full Make gate | `PITHEAD_IMPL=bash make test`: stops at cache Markdown lint, exit 2 | `PITHEAD_IMPL=go make test` with the full Go adapter environment above: same failure, exit 2 |

The full Go dashboard command was:

```bash
PITHEAD_IMPL=go \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
make test-dashboard
```

The 3719 count comprises 3716 existing dashboard tests and three snapshot tests
added in the previous review slice. No original test was rewritten or replaced.
Startup fixtures do not run daemon clients or polling loops; those runtime
contracts remain unproved by the startup cases.

Patch coverage uses the existing `make test-patch-coverage` gate. Reference passed
at 92%. Go-only failed at 84%; appending the presentation A/B comparisons with
the following command passed at 93%:

```bash
PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" \
make test-go-dashboard-overview-parity test-go-dashboard-fleet-parity
make test-patch-coverage
```

The storage target was also rerun with those coverage append flags. These patch
percentages describe the tracked diff against the existing coverage base; new
untracked files are not included until the operator commits them. The appended
coverage XML covers 236 of 258 executable lines in the new Python bridge (91.47%).
Go units and explicit bridge failure cases supplement that gate. The gate is unchanged.

## Limits and follow-up

The reference uses second-resolution quarantine names. A failed recovery followed
by an immediate retry in the same second can overwrite the earlier quarantine.
The native implementation preserves that behavior; correcting it requires a
paired reference change under a separately agreed parity policy.

The full `make test` gate still stops at Markdown lint on third-party files under
the required local uv cache, in both modes. Shell lint passes. No original lint
rule was changed. The starting-SHA file-budget override remains necessary for
the pre-existing version-branch differences documented in PARITY.md.

File-budget, generated CLI, docs voice, path references and operator strings
checks pass with the starting-SHA budget override. Changed Python Ruff checks,
format checks, YAML lint and `git diff --check` pass. Topology selftests still
fail on the BSD host as recorded in PARITY.md; their rules remain unchanged.
The pinned Markdown tool passes the four changed docs with the original rules
and a temporary config limiting globs to those docs:
`npx --yes markdownlint-cli2@0.18.1 --config .go-cache/storage.markdownlint-cli2.jsonc`.

Docker, live appliance and privileged Linux checks were not run. Cross-compilation
does not prove Linux runtime behavior. Wizard/control, production selection and
release/dashboard/appliance artifacts are next in the operator's order.
