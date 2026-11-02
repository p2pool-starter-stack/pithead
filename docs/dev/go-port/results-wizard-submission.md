# Wizard rig and restore submission parity

Go now supplies the rig and restore submission plans. The original Python
handlers remain the reference; existing tests, fixtures and checks are unchanged.
Typed configuration submission remains Python orchestration.

## Native boundary

`go/internal/dashboard/wizard/submission.go` validates the rig pool, optional
installer target, archive size and passphrase byte length. It selects the
ordered publication actions and persistent versus volatile archive destination.
Rig request JSON retains field order and omits empty worker/password fields.
Installer requests retain disk confirmation and wipe policy; the rig USB path
does not publish a disk trigger. Validation errors publish no submission inputs.

Restore phases preserve the original side effects and lazy reads: clear the
host verdict and restate `stick=0`, require an upload, read and check its size,
then encode and check the passphrase, then inspect installer disks. Publication
clears sidecars and the retry snapshot, stages the passphrase in volatile
storage, publishes any disk request, writes the archive and finally publishes
the active marker. Only an archive beginning with the existing encryption
prefix may use persistent spool storage. The Go failure plan retains the generic
500 response and unsafe-cleanup suffix.

`go_wizard_submission.py` is the transport and action interpreter. Python keeps
authentication, TLS availability, aiohttp multipart limits/parsing, the shared
submission lock, string/Unicode normalization and JSON serialization. The
planner receives metadata, never archive or passphrase contents. Archive bytes
use the existing raw-stream native atomic writer. Rig credentials cross helper
stdin/stdout, never argv or counters. Existing module-level writer hooks remain
the fault-injection boundary; their normal implementation calls native Go.

The bridge does not offload publication or add an await between its actions,
so the existing lock still covers every write and cleanup. Failed staging uses
the native cleanup path and generic response. Helper/protocol errors propagate;
there is no Python rig/restore planning fallback in Go mode. Python continues
to own typed config submission, keep-existing-install orchestration, control
HTTP handling, polling and business SQL. Production selection and shipping
artifacts remain pending.

## Adapters and native proof

Only new files under `tests/go-parity/` adapt the unchanged oracle:

- `dashboard_wizard_submission_plugin.py` layers over the existing wizard
  adapters, makes both captured original submission bodies fatal and counts
  native operation/phase successes and error classes without input values.
- `dashboard_wizard_submission_compare.py` adds three separate-process A/B
  comparisons for exact HTTP body/status and spool bytes: rig JSON and markers,
  encrypted restore staging and plaintext restore remaining volatile.
- `dashboard_wizard_submission_guards.py` builds isolated source overlays.
  Renaming the native rig request fails the unchanged rig publication test;
  reversing archive placement fails the unchanged restore publication test.
  Both require the expected assertion failure and native-call evidence.

`make test-go-dashboard-wizard-submission-parity` runs the original wizard,
shared defaults and config-version paths plus those five new cases. The bounded
Go CI job includes this target. Pre-port targets and checks retain their behavior.

## Commands and results

Commands use the locked Python 3.11 environment and absolute worktree-local
Go/uv caches. No Docker, live stack or fleet job was used.

```bash
cd dashboard
PITHEAD_IMPL=python .venv/bin/python -m pytest \
  tests/web/test_wizard*.py tests/web/test_config_defaults.py \
  tests/service/test_config_version.py
```

An isolated archive of `a73ffced33800de9435779a9cabef53864455acb` and the current
reference each pass 334 original tests using the command above, the installed
interpreter and their corresponding packages.

```bash
make test-go-dashboard-wizard-submission-parity
PITHEAD_IMPL=go \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin,dashboard_wizard_submission_plugin \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_XDIST_AUTO_NUM_WORKERS=1 make test-dashboard
```

The focused Go target passes 339 tests: the same 334 originals, three new paired
comparisons and two mutation controls. Parent-process counters are recorded
below; subprocess comparison and mutation-worker counts are not inferred.

| Native phase | Successful planner responses |
|---|---:|
| Rig start / publish | 26 / 21 |
| Restore start / size / passphrase / publish | 22 / 21 / 20 / 19 |
| Restore failure response | 5 |

No planner exception was recorded. Expected HTTP validation failures are
successful planner responses, not helper exceptions. Original fault tests still
exercise explicit replace/unlink interpositions and writer callbacks through
the earlier transaction adapter; those cases are not Python planning fallback.

The full reference arm uses the same suite and threshold with isolated XML:

```bash
cd dashboard
PITHEAD_IMPL=python PYTEST_XDIST_AUTO_NUM_WORKERS=1 .venv/bin/python -m pytest \
  -n auto --cov=mining_dashboard --cov-report=term-missing \
  --cov-report=xml:../.go-cache/coverage-wizard-submission-reference.xml \
  --cov-fail-under=80
```

Full-arm counts include all 3716 frozen original tests plus three snapshot tests
added by an earlier slice. They do not establish a complete native backend.
Xdist-worker native counts are not inferred from the parent process. Local
duration is not benchmark evidence.

```bash
make go-build go-dashboard-build
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go -C go build -o "../.go-cache/wizard-submission-linux-$arch/" ./cmd/pithead ./cmd/dashboard
done
```

| Check | Reference | Go selection |
|---|---|---|
| Focused original paths | 334 passed at frozen start and current head | Same 334 passed with captured original rig/restore bodies fatal |
| New submission target | Three separate-process A/B comparisons | 339 passed, including five new cases and two mutation controls |
| Full dashboard | 3719 passed; 89.51% Python coverage | 3719 passed; 81.84% Python coverage |
| Isolated patch gates | Reference-only gate fails at 43% | Go-only gate fails at 85%; combined A/B gate passes at 92% |
| Go checks | Reference retained | Full race units, vet, module verification and CGO-free Linux amd64/arm64 command builds passed |
| Full Make | Stops at dependency-cache Markdown lint | Stops at the same gate; original checks unchanged |

Fresh full-arm data uses separate `COVERAGE_FILE` paths under `.go-cache/`.
The unchanged patch gate is graded separately on each full-arm XML. The combined
report joins saved reference/Go data, then appends the focused submission target:

```bash
mkdir -p .go-cache/coverage-wizard-submission-combined
cp .go-cache/coverage-wizard-submission-reference \
  .go-cache/coverage-wizard-submission-combined/.coverage.reference
cp .go-cache/coverage-wizard-submission-go \
  .go-cache/coverage-wizard-submission-combined/.coverage.go
cd dashboard
COVERAGE_FILE="$PWD/../.go-cache/coverage-wizard-submission-combined/.coverage" \
  .venv/bin/python -m coverage combine --keep ../.go-cache/coverage-wizard-submission-combined
cd ..
COVERAGE_FILE="$PWD/.go-cache/coverage-wizard-submission-combined/.coverage" \
PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" \
  make test-go-dashboard-wizard-submission-parity
make test-patch-coverage
```

The combined gate measures 41 tracked changed Python files and 1402 lines,
missing 106. Combined Python coverage is 96.71%. This is combined A/B evidence,
not a Go-only patch-coverage pass. The tracked-diff gate excludes new untracked
files until the operator commits; the new bridge is measured separately at
71/72 executable lines, and the shared wizard bridge at 91/92. The missing new
bridge line is its unsupported-action exception. The original suites and
fixtures remain unchanged against the frozen starting commit.

Both full Make attempts pass shell lint before failing Markdown lint on
third-party files in the required local uv cache. Changed project Markdown is
checked separately. One final Markdown invocation without the local npm cache
was refused by the sandbox; its offline local-cache retry passed.
Correctness and security reviews found no remaining issues.
GNU-first topology, including enumeration of untracked additions, file budget
with the starting-SHA override, generated CLI, Ruff lint/format, YAML, docs
voice/path references, operator strings and diff checks pass. No original check
or budget ceiling changed.

Next: typed config and keep-existing-install submission, remaining control HTTP
orchestration, then production selection and shipping artifacts with reference
fallback. Linux, Docker/image, appliance and privileged proofs remain listed in
[PARITY.md](PARITY.md#unavailable-and-known-host-constraints).
