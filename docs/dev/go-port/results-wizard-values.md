# Wizard defaults and metadata parity

Go now supplies disk-aware Tari defaults, new-machine answer merging, explicit
configuration materialization, inventory row policy, remembered-change
deduplication and spool removal. Existing suites, fixtures and checks are
unchanged; the Bash and Python implementations remain the reference.

## Native boundary

`go/internal/dashboard/wizard/values.go` owns these decisions:

- Select the first matching disk, retain a held Tari chain only under the
  original wipe rule, and request the runtime default only when needed.
- Merge machine defaults with the selected Tari mode, preserving value order.
- Strip defaults and select explicit materialization paths while preserving
  retained object aliases and the original object for false-valued references.
  Materialization paths are validated in either reference case.
- Build inventory rows and optional capacity fields in their original order.
- Validate remembered changes and deduplicate them with Python equality rules,
  including boolean/integer equality and non-finite value identity.
- Check spool-file existence and unlink in order, preserving partial removal,
  missing and dangling-link behavior, and the first unlink failure.

`go_wizard_values.py` retains runtime default providers and callback execution.
The Tari default provider remains lazy, and new-machine defaults are acquired
before selecting Tari policy. Python normalizes inventory text with its original
`splitlines`, `isdigit` and `int` operations; Go owns row construction and capacity
selection and forwards conversion failures. The existing tagged value codec
preserves ordering, arbitrary-size integers, lone surrogates and shared NaNs.
Python applies native alias/materialization paths and serializes remembered
changes with the original JSON writer hook. Spool operations use Go filesystem
calls in production; patched unlink hooks in the oracle use explicit callbacks.

The original six functions remain available only as the reference. Go-selected
calls have no policy fallback. Raw document parsing, runtime providers,
preparation sequencing, probes, remaining control HTTP orchestration and polling
remain Python. Production selection and shipping artifacts remain pending.

## Adapters and native proof

Only new files under `tests/go-parity/` adapt the original suites:

- `dashboard_wizard_values_plugin.py` layers over the typed-submission adapter,
  makes all six captured original function bodies fatal and counts native
  successes and exception classes without recording values.
- `dashboard_wizard_values_io.py` forwards patched `os.unlink` hooks through the
  native protocol. It preserves injected failure timing and filesystem results;
  it does not implement deletion policy in Python.
- `dashboard_wizard_values_compare.py` adds five separate-process A/B cases for
  first-match disks and strict booleans, explicit aliases, deduplication and
  callback order, Unicode inventory integers/errors, and partial spool deletion.
- `dashboard_wizard_values_guards.py` builds two isolated source overlays.
  Breaking the held-chain rule fails the unchanged Tari default test. Disabling
  materialization fails the unchanged sparse-submit test. Each mutation requires
  its expected failure and native-call evidence.

The additive target and bounded Go CI job run the original wizard, shared
defaults and config-version suites plus the seven new cases. No original target,
test or threshold changed.

## Commands and results

All commands use the locked Python 3.11 environment and absolute worktree-local
Go/uv caches. No Docker, live stack or fleet job was used.

```bash
cd dashboard
PITHEAD_IMPL=python .venv/bin/python -m pytest \
  tests/web/test_wizard*.py tests/web/test_config_defaults.py \
  tests/service/test_config_version.py
cd ..
make test-go-dashboard-wizard-values-parity
PITHEAD_IMPL=go COVERAGE_FILE="$PWD/.go-cache/coverage-wizard-values-go" \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin,dashboard_wizard_values_plugin \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_XDIST_AUTO_NUM_WORKERS=1 make test-dashboard
```

An isolated archive of `a73ffced33800de9435779a9cabef53864455acb` and the current
reference each pass 334 original focused tests with their corresponding packages.
Full counts include 3716 frozen original tests and three snapshot tests added by
an earlier slice. They do not prove a complete native backend. Parent-process
helper counts do not include subprocess comparisons or xdist workers. Local test
duration is not benchmark evidence.

```bash
cd dashboard
PITHEAD_IMPL=python PYTEST_XDIST_AUTO_NUM_WORKERS=1 \
COVERAGE_FILE="$PWD/../.go-cache/coverage-wizard-values-reference" \
  .venv/bin/python -m pytest \
  -n auto --cov=mining_dashboard --cov-report=term-missing \
  --cov-report=xml:../.go-cache/coverage-wizard-values-reference.xml \
  --cov-fail-under=80
cd ..
make go-build go-dashboard-build
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go -C go build -o "../.go-cache/wizard-values-linux-$arch/" ./cmd/pithead ./cmd/dashboard
done
```

| Check | Reference | Go selection |
|---|---|---|
| Focused original paths | 334 passed at frozen start and current head | Same 334 passed with six original bodies fatal |
| New values target | Five separate-process A/B comparisons | 341 passed, including seven new cases and two mutation controls |
| Full dashboard | 3719 passed; 87.93% Python coverage | 3719 passed; 81.05% Python coverage |
| Isolated patch gates | Reference-only gate fails at 38% | Go-only gate fails at 85% |
| Go checks | Reference retained | Full race units, vet, module verification and CGO-free Linux amd64/arm64 command builds passed |
| Full Make | Stops at dependency-cache Markdown lint | Stops at the same gate; original checks unchanged |

The focused target records the following successful parent-process native calls;
no values-helper errors or I/O interpositions occurred in that process.

| Operation | Successful responses |
|---|---:|
| Tari selection | 90 |
| New-machine answers | 74 |
| Explicit configuration | 80 |
| Inventory rows | 233 |
| Remembered changes | 64 |
| Spool removal | 52 |

Injected unlink failure is proved separately by the new paired case and its
callback adapter. Other original writer faults retain their existing explicit
transaction interpositions. None invokes a Python values-policy fallback.

Fresh full-arm coverage data is saved separately. The unchanged patch gate is
graded once per arm before combining reference and Go data and appending the
focused values target:

```bash
mkdir -p .go-cache/coverage-wizard-values-combined
cp .go-cache/coverage-wizard-values-reference \
  .go-cache/coverage-wizard-values-combined/.coverage.reference
cp .go-cache/coverage-wizard-values-go \
  .go-cache/coverage-wizard-values-combined/.coverage.go
cd dashboard
COVERAGE_FILE="$PWD/../.go-cache/coverage-wizard-values-combined/.coverage" \
  .venv/bin/python -m coverage combine --keep ../.go-cache/coverage-wizard-values-combined
cd ..
COVERAGE_FILE="$PWD/.go-cache/coverage-wizard-values-combined/.coverage" \
PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" \
  make test-go-dashboard-wizard-values-parity
make test-patch-coverage
```

The combined A/B patch gate passes at 92%: 43 tracked changed Python files,
1577 measured lines and 113 missing lines. This is combined evidence, not a
Go-only patch-coverage pass. The tracked-diff gate excludes the new untracked
bridge until the operator commits; it measures 81/84 executable lines separately
in the combined XML, and the shared wizard bridge measures 95/96. The uncovered
new lines are a non-object config guard and two inventory error-normalization
lines; the latter are exercised by the separate-process comparison without
subprocess coverage collection. Combined Python coverage is 96.68%.

Correctness and security reviews found no remaining issues. GNU-first topology,
including untracked additions, file budget with the starting-SHA override,
generated CLI, Ruff lint/format, YAML, docs voice/path references, operator
strings, changed Markdown and diff checks pass. Original tests and fixtures are
unchanged against the frozen starting commit. Both full Make attempts pass shell
lint before failing Markdown lint on third-party text in the required local uv
cache; no original check or ceiling changed.

Next: wizard preparation sequencing and remaining control HTTP orchestration,
then production selection and release/dashboard/appliance shipping artifacts
with reference fallback. Linux, Docker/image, appliance and privileged proofs
remain listed in [PARITY.md](PARITY.md#unavailable-and-known-host-constraints).
