# Wizard typed configuration preparation parity

Go selects the typed submission's source, preparation, defaults and name-validation phases.

## Native boundary

`go/internal/dashboard/wizard/preparation.go` selects raw parsing versus form
building, requires an object, prepares the candidate with legacy conflicts
rejected, decides whether a prior attempt suppresses new-install defaults,
prepares and merges those defaults, then validates the machine name. It reuses
the native config transforms and tagged values, preserving ordered keys,
nonfinite numbers and Unicode values.

`go_wizard_preparation.py` executes those phases through the bounded helper
channel. Python retains standard-library document decoding, form/provider
callbacks, platform normalization and attribute-access guards for malformed
provider shapes. The first prior-attempt read controls defaults; a separate
second read supplies name validation. A prior attempt may change between them.
No spool write, authentication sidecar, install check or node probe occurs inside
preparation. Existing typed submission plans perform those later operations.

Public reference selection retains the original server implementation and helper
paths. Go installation replaces the typed bridge's config-source function and
preparation block. There is no compatibility fallback in this helper. Native
unavailability and malformed envelopes raise backend errors; input validation
retains the original parse/config HTTP error boundaries. No original server body
or test was edited.

Wizard-state response assembly still invokes the captured Python state builder.
Remaining state/polling, worker-specific HTTP, production selection and shipping
are separate work. This slice does not establish a complete native dashboard.

## Adapters and native proof

Three new files adapt the unchanged suites:

- `dashboard_wizard_preparation_plugin.py` layers over the existing control,
  document, values and typed adapters. It makes the captured config-source body
  fatal and counts preparation phases and errors. The parent adapter already
  makes the original typed submission handler fatal. Trace files contain phase
  names only.
- `dashboard_wizard_preparation_compare.py` adds four separate-process A/B cases
  covering raw/form sources, fresh defaults, changing prior attempts, existing
  attempts and provider failures. Two native-failure cases require HTTP 500 for
  unavailable helpers and malformed plans. Three sentinel cases prove unset,
  `bash` and `python` selection do not execute a native helper.
- `dashboard_wizard_preparation_guards.py` compiles two source overlays. Skipping
  fresh defaults must fail the unchanged sparse-browser-defaults test; permitting
  legacy conflicts must fail the unchanged conflict-submission test. Each control
  requires the expected oracle failure and evidence of its native phase.

The additive `test-go-dashboard-wizard-preparation-parity` target runs 334
original wizard/defaults/version tests and eleven supplementary cases. It is
included in the existing bounded Go CI job. Existing suites, fixtures, targets,
thresholds and lint rules remain unchanged.

## Commands and results

Runs use locked Python 3.11, worktree-local absolute Go/uv caches, and an isolated
frozen archive of `a73ffced33800de9435779a9cabef53864455acb`. No Docker, live stack,
reserved hardware or fleet job was used. Local durations are not performance
evidence.

```bash
cd dashboard
PITHEAD_IMPL=python .venv/bin/python -m pytest tests/web/test_wizard*.py \
  tests/web/test_config_defaults.py tests/service/test_config_version.py
cd ..
make test-go-dashboard-wizard-preparation-parity
make go-dashboard-build
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go -C go build -o "../.go-cache/preparation-linux-$arch/" ./cmd/pithead ./cmd/dashboard
done
```

Frozen and current references each pass all 334 focused originals. The final
focused target passes 345 tests: those originals and eleven additions. Its parent
process records 95 source decisions, 84 object gates, 83 strict preparations,
83 previous-attempt decisions, 64 defaults merges and 66 successful name checks.
Four object errors, one legacy-conflict error and seventeen name errors are
expected native `ValueError` results. No compatibility fallback is recorded.
These counts exclude separate-process comparisons and xdist workers.

Both source-mutation controls pass by observing failures in the unchanged oracle.
All Go race tests, vet, module verification and static Linux builds pass. The
independent correctness and security reviews found no blocking issue in the
final source. Static compilation does not prove Linux execution or image wiring.

Full dashboard runs use the same original Make coverage threshold. Their 3719
tests consist of 3716 frozen originals and three snapshot tests added by an
earlier slice. Coverage is graded for each arm before any combination.

```bash
cd dashboard
PITHEAD_IMPL=python PYTEST_XDIST_AUTO_NUM_WORKERS=1 \
COVERAGE_FILE="$PWD/../.go-cache/coverage-preparation-reference-final" \
  .venv/bin/python -m pytest -n auto --cov=mining_dashboard \
    --cov-report=term-missing \
    --cov-report=xml:../.go-cache/coverage-preparation-reference-final.xml \
    --cov-fail-under=80
cd ..
PITHEAD_IMPL=go PYTEST_XDIST_AUTO_NUM_WORKERS=1 \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin,dashboard_wizard_preparation_plugin \
COVERAGE_FILE="$PWD/.go-cache/coverage-preparation-go-final" make test-dashboard
```

| Check | Result |
| --- | --- |
| Frozen and current focused reference | 334 passed each |
| Go focused target | 345 passed |
| Full reference | 3719 passed; 85.13% Python coverage |
| Full Go | 3719 passed; 80.02% Python coverage |
| Reference patch coverage alone | 31%; fails the unchanged 90% threshold |
| Go patch coverage alone | 86%; fails the unchanged 90% threshold |
| Combined arms plus focused target | 92% patch coverage; 153/1946 lines missing; passes |
| New bridge measured separately | 53/58 executable lines, 91.38% combined coverage |

The combined total Python coverage is 96.41%. The patch tool sees all 46 tracked
changed Python files. It excludes the new untracked preparation bridge until the
operator commits; the separate executable-line count above measures that file.
Combining the arms does not establish a Go-only patch-coverage pass. Native
availability cases execute in subprocesses and do not add parent-process coverage
for the defensive bridge branches.

```bash
mkdir -p .go-cache/coverage-preparation-combined
cp .go-cache/coverage-preparation-reference-final \
  .go-cache/coverage-preparation-combined/.coverage.reference
cp .go-cache/coverage-preparation-go-final \
  .go-cache/coverage-preparation-combined/.coverage.go
cd dashboard
COVERAGE_FILE="$PWD/../.go-cache/coverage-preparation-combined/.coverage" \
  .venv/bin/python -m coverage combine --keep ../.go-cache/coverage-preparation-combined
cd ..
COVERAGE_FILE="$PWD/.go-cache/coverage-preparation-combined/.coverage" \
PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" \
  make test-go-dashboard-wizard-preparation-parity
make test-patch-coverage
```

Affected Python, YAML, topology, generated-CLI, documentation voice, path-reference
and operator-string checks pass. File-budget checks pass with the documented
starting-SHA override; no budget entries changed. GNU-first topology checks also
include untracked source through the additive inventory wrapper. All new files
remain below 400 lines. Changed Markdown passes its existing lint configuration.
Both full `make test` attempts pass shell and Python lint, then fail Markdown lint
on third-party files in the required local uv cache. No check was weakened or
removed. Original tests still match the frozen starting commit.

Wizard-state assembly and worker-specific control HTTP/I/O remain the next
backend work. Production selection, shipping artifacts, Linux execution and
privileged fleet proof remain pending.
