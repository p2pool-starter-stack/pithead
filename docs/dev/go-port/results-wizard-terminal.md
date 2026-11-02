# Wizard terminal action parity

Go now owns authenticated handoff readiness, acknowledgement and keep-role
markers, retry response decisions and ordered retry cleanup. The original
Python handlers remain the reference. Existing tests and fixtures are unchanged.

## Native boundary

`go/internal/dashboard/wizard/terminal.go` implements four terminal operations:

- Handoff reads the existing volatile directory, returning 404 for absent or
  stripped-empty content. Ready responses retain `Cache-Control: no-store`.
- Acknowledgement requires a present handoff, including an empty one, and
  atomically publishes `handoff-ack` before returning `provisioning`.
- Keep-role requires an existing named saved role and atomically publishes
  `keep-role` before returning `kept`.
- Retry requires the captured stage to equal `failed`, then removes `error.txt`,
  `installing` and `setup-failed` in that order. It follows the original existence
  check before unlinking, leaves broken links intact and stops on the first
  unlink error, preserving any completed removals.

The operations reuse the previously proven spool reader, saved-role policy and
atomic writer. Empty handoff-directory settings retain the spool fallback.
The JSON-lines protocol propagates helper and filesystem errors without a
Python action fallback. Credentials cross stdin/stdout, never argv or counters.

`go_wizard_terminal.py` installs the three route handlers and retry factory
before the original route table is built. Python retains aiohttp redirects,
JSON parsing/serialization and the existing native cookie-policy call.
Denied requests return the original 401 or 302 without starting a terminal
helper. The Go authorization guards remain in the native operation boundary.

The retry factory preserves authentication, one stage callback, then lazy spool
resolution only when Go selects cleanup. Both native calls use the same captured
stage. Callbacks and native operations execute off the event loop. A factory
lock serializes stage capture through cleanup; a shielded task holds that lock
until work finishes even if the request is cancelled. Detached task exceptions
are retrieved without changing propagation to a waiting caller.

Python still owns submission/upload/restore orchestration, remaining control
HTTP handling, polling and business SQL. Production container selection and
release/dashboard/appliance shipping integration remain pending.

## Adapters and native proof

Only new files under `tests/go-parity/` adapt the original suites:

- `dashboard_wizard_terminal_plugin.py` layers over the config/policy/transaction
  adapters and makes all captured original terminal handler/factory bodies fatal.
  It records native operations and error classes without recording input values.
- `dashboard_wizard_terminal_compare.py` has four separate-process A/B cases
  covering exact HTTP body/status/location/cache headers, JSON edge values,
  separate and empty handoff directories, marker bytes/modes, missing roles,
  broken links and partial cleanup failures. Seven transport cases check lazy
  callbacks and prove denied requests call no terminal helper or retry callback.
- `dashboard_wizard_terminal_concurrency.py` uses the real Go helper and a
  blocked stage callback. It proves a second request waits until cleanup ends,
  then returns 409, both normally and after the first caller is cancelled.
- `dashboard_wizard_terminal_guards.py` builds isolated source overlays. Removing
  readiness validation fails the unchanged handoff-404 assertion; removing the
  marker write fails the unchanged acknowledgement assertion; reversing the
  retry gate fails the unchanged non-failure assertion. Each control requires
  the expected original assertion failure and successful native-call evidence.

The added target runs all original wizard tests, shared defaults tests and
service config-version tests. Earlier port-added wizard/channel targets now
load this adapter too. The bounded Go CI job includes the new target. No pre-port
target, test, fixture, lint rule or threshold changed.

## Commands and results

Commands use absolute worktree-local Go/uv caches and the locked Python 3.11
environment. No Docker, live stack or fleet job was used.

```bash
cd dashboard
PITHEAD_IMPL=python .venv/bin/python -m pytest \
  tests/web/test_wizard*.py tests/web/test_config_defaults.py \
  tests/service/test_config_version.py
```

The current reference and an isolated archive of
`a73ffced33800de9435779a9cabef53864455acb` each pass 334 original tests using
that command, the installed interpreter and their corresponding packages.
The 16 new cases supplement the unchanged oracle.

```bash
make test-go-dashboard-wizard-terminal-parity
PITHEAD_IMPL=python PYTEST_XDIST_AUTO_NUM_WORKERS=1 make test-dashboard
PITHEAD_IMPL=go \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin,dashboard_wizard_terminal_plugin \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_XDIST_AUTO_NUM_WORKERS=1 make test-dashboard
```

The focused target passes 350 tests: 334 original tests and 16 new cases.
Its parent-process counters record three handoff reads, two acknowledgements,
two keep-role actions and 11 retry phases. The retry total includes the two new
concurrency cases; subprocess comparisons and mutation-worker counts are not
inferred from these counters. Denied requests are verified separately as zero
terminal-helper calls.

| Check | Reference | Go selection |
|---|---|---|
| Focused original paths | 334 passed at frozen start and current head | Same 334 passed with captured original terminal bodies fatal |
| New terminal target | Four separate-process A/B comparisons | 350 passed, including 16 new cases and three mutation controls |
| Full dashboard | 3719 passed; 90.14% Python coverage | 3719 passed; 82.35% Python coverage |
| Isolated patch gates | Reference-only gate fails at 45% | Go-only gate fails at 84%; combined A/B gate passes at 92% |
| Go checks | Reference retained | Full race units, vet, module verification and CGO-free Linux amd64/arm64 command builds passed |
| Full Make | Stops at dependency-cache Markdown lint | Stops at the same gate; no original check changed |

Fresh coverage data for the full reference and Go arms use separate
`COVERAGE_FILE` paths under `.go-cache/`. The final reference invocation uses
the same suite, options and 80% threshold with an isolated XML output:

```bash
cd dashboard
PITHEAD_IMPL=python PYTEST_XDIST_AUTO_NUM_WORKERS=1 .venv/bin/python -m pytest \
  -n auto --cov=mining_dashboard --cov-report=term-missing \
  --cov-report=xml:../.go-cache/coverage-wizard-terminal-reference-final.xml \
  --cov-fail-under=80
```

The full count includes all 3716 frozen original tests and three snapshot cases
added by an earlier slice. Xdist-worker native counts are not inferred from the
parent process. Local test duration is not benchmark evidence.

```bash
make go-build go-dashboard-build
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go -C go build -o "../.go-cache/wizard-terminal-linux-$arch/" ./cmd/pithead ./cmd/dashboard
done
```

The unchanged patch gate is graded separately on each full-arm XML. A combined
A/B report joins the independently retained reference/Go coverage data, then
appends the focused terminal target with coverage enabled. It is a combined
coverage result, not a Go-only patch-coverage claim. Native ownership is proved
by fatal original bodies and the mutation controls above.

The combined report uses the standard coverage tool on saved data copies:

```bash
mkdir -p .go-cache/coverage-wizard-terminal-combined
cp .go-cache/coverage-wizard-terminal-reference \
  .go-cache/coverage-wizard-terminal-combined/.coverage.reference
cp .go-cache/coverage-wizard-terminal-go \
  .go-cache/coverage-wizard-terminal-combined/.coverage.go
cd dashboard
COVERAGE_FILE="$PWD/../.go-cache/coverage-wizard-terminal-combined/.coverage" \
  .venv/bin/python -m coverage combine --keep ../.go-cache/coverage-wizard-terminal-combined
cd ..
COVERAGE_FILE="$PWD/.go-cache/coverage-wizard-terminal-combined/.coverage" \
PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" \
  make test-go-dashboard-wizard-terminal-parity
make test-patch-coverage
```

The combined gate measures 40 tracked changed Python files and passes at 92%;
combined Python coverage is 96.70%. The tracked-diff gate does not include new
untracked files until the operator commits. The new bridge measures 56/57
executable lines separately; the shared wizard bridge measures 89/90 lines.
Original tests and fixtures remain unchanged against the frozen starting commit.

Both full Make attempts pass shell lint before failing Markdown lint on
third-party files in the required local uv cache. Changed project Markdown is
checked separately. Independent correctness and security reviews pass after the
denial and retry-concurrency fixes. GNU-first topology (including additive
enumeration of new untracked files), file budget with the starting-SHA override,
generated CLI, Ruff lint/format, YAML, docs voice/path references, operator
strings, changed-document Markdown and diff checks pass. No original check or
budget ceiling changed.

## Remaining work

Port wizard submission/upload/restore and remaining control HTTP orchestration,
then production selection and shipping artifacts with reference fallback.
Remaining state/earnings and polling also keep this a hybrid backend. Linux-only
CLI, Docker/image, appliance, privileged and fleet proofs remain unavailable or
unrun locally.
