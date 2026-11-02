# Wizard-state assembly parity

Go prepares and assembles the authenticated wizard-state response.

## Native boundary

`go/internal/dashboard/wizard/state.go` prepares the last attempt against the
runtime reference, selects migration-note persistence, selects handoff reads only
in the handoff stage, and decides whether fresh-machine defaults are needed. It
merges the effective config, selects setup/installer mode and deduplicates changes
before assembling all seventeen response fields in the original order.

`go_wizard_state.py` executes these phases with the existing providers. Python
retains spool/provider I/O, platform and object-shape normalization, standard-library
handoff JSON parsing, saved-probe filtering and aiohttp serialization. Tagged values
preserve key order, Unicode, nonfinite numbers and arbitrary saved JSON shapes.
The final body uses one captured input envelope; it performs no additional reads.
Independent disk reads still occur at their original positions and may differ.

The bridge preserves this sequence: authentication, reference/stage/attempt,
preparation, recovery, optional migration-note persistence, budget, optional raw
handoff, installer mode, optional defaults, config merge, error/inventory/rig/wipe
providers, handoff parsing, saved role, saved probe, changes and response. A bad
handoff stops after data-wipe collection and before saved-role collection.

`go_wizard.state_builder` now calls the native phase executor instead of running
the captured Python state coroutine. The existing submission lock, off-loop work,
in-flight coalescing and authentication checks remain. Responses keep
`Cache-Control: no-store`. Public reference selection retains the original server.
Native helper faults and malformed plans fail as backend errors without fallback.

This slice does not port providers, polling, worker-specific HTTP or production
selection. It does not establish a fully native dashboard.

## Adapters and native proof

Three new files under `tests/go-parity/` supply supplementary proof:

- `dashboard_wizard_state_plugin.py` layers over the preparation and earlier
  adapters, makes the captured original async state builder fatal, and counts
  native phases/errors. Optional traces contain phase names only.
- `dashboard_wizard_state_compare.py` adds five separate-process A/B cases for
  HTTP status/body bytes/cache/type, provider order, distinct inventory reads,
  lazy defaults/writes, migration persistence, malformed handoff timing and saved
  probe validity. Six in-process native-boundary cases require `RuntimeError` for
  unavailability, wrong phases, invalid tagged values, missing preparation flags
  and bad config/body shapes. Three reference-mode sentinels reject native calls.
- `dashboard_wizard_state_guards.py` builds two isolated source overlays.
  Returning only the reference config must fail the unchanged rejected-attempt
  test; dropping the node probe must fail the unchanged failed-probe test. Each
  control requires one expected oracle failure and all three native phase traces.

The additive `test-go-dashboard-wizard-state-parity` target includes all 334
unchanged wizard/defaults/version tests, the existing port-added twelve-request
coalescing test, and sixteen new comparison/boundary/mutation cases. It is wired
into the bounded Go CI job. No original suite, fixture, threshold or lint rule was
edited, replaced or weakened.

## Commands and results

Runs use locked Python 3.11 and absolute worktree-local Go/uv caches. No Docker,
live stack, fleet job or benchmark was used. Static Linux compilation is separate
from Linux execution and image validation.

```bash
make test-go-dashboard-wizard-state-parity
make go-dashboard-build
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go -C go build -o "../.go-cache/wizard-state-linux-$arch/" ./cmd/pithead ./cmd/dashboard
done
```

The focused target passes 351 tests with sixteen existing warnings. Its parent
records seventy calls to each of `prepare`, `config` and `response`, and zero
native errors. Counts exclude subprocess comparisons, xdist workers and the six
deliberate helper interpositions. Both source-mutation controls pass by observing
the required failures in unchanged tests.

Frozen and current reference arms each pass the same 334 focused originals. Full
dashboard runs contain 3716 frozen originals and three snapshot tests added by
an earlier slice. Both full arms pass all 3719 assertions. Reference Python
coverage is 84.62%; Go coverage from that run alone is 79.98%.

The locked coverage plugin applies integer precision to its exit decision: the
standalone Go run returns zero while printing an 80% threshold warning for the
raw 79.98% value. This report does not treat that as measured 80% coverage. No
threshold, precision setting or plugin was changed. Appending the focused target
reaches 84.22%, but includes A/B reference subprocesses and is labelled comparison
coverage. A separate Go-only matrix includes just the six native-boundary cases
with the full suite, excluding A/B, reference sentinels and mutation subprocesses.
That matrix passes all 3725 tests and the unchanged coverage gate at 80.03%,
with no reference subprocess execution.

| Check | Result |
| --- | --- |
| Frozen and current focused reference | 334 passed each |
| Focused Go target | 351 passed |
| Full reference | 3719 passed; 84.62% coverage |
| Standalone full Go | 3719 assertions pass; 79.98% coverage; rounded successful exit |
| Full Go plus six native-boundary cases | 3725 passed; 80.03% coverage |
| Go plus focused A/B comparison append | 351 passed; cumulative 84.22% coverage |
| Combined reference/comparison patch gate | 92%; 157/2013 lines missing; passes |
| New state bridge measured separately | 61/64 executable lines; 95.31% |

```bash
cd dashboard
PITHEAD_IMPL=python PYTEST_XDIST_AUTO_NUM_WORKERS=1 \
COVERAGE_FILE="$PWD/../.go-cache/coverage-wizard-state-reference" \
  .venv/bin/python -m pytest -n auto --cov=mining_dashboard \
    --cov-report=term-missing \
    --cov-report=xml:../.go-cache/coverage-wizard-state-reference.xml \
    --cov-fail-under=80
cd ..
PITHEAD_IMPL=go PYTEST_XDIST_AUTO_NUM_WORKERS=1 \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin,dashboard_wizard_state_plugin \
COVERAGE_FILE="$PWD/.go-cache/coverage-wizard-state-go" make test-dashboard
PITHEAD_IMPL=go PYTEST_XDIST_AUTO_NUM_WORKERS=1 \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin,dashboard_wizard_state_plugin \
PYTEST_ADDOPTS="tests $PWD/tests/go-parity/dashboard_wizard_state_compare.py::test_native_plan_failures_raise_without_reference_fallback" \
COVERAGE_FILE="$PWD/.go-cache/coverage-wizard-state-native-only/.coverage" make test-dashboard
```

Reference-only patch coverage is 30%; the standalone Go arm is 86%. The Go arm
plus only six native-boundary cases is also 86% (271/2013 lines missing), while
the focused comparison append is 87%. All four fail the unchanged 90%
threshold. Combining measured reference and appended comparison data passes at
92%: 157 of 2013 changed executable lines remain uncovered, with all 47 tracked
changed Python files present. Combined total Python coverage is 96.41%.

The new untracked state bridge is excluded from the patch inventory until the
operator commits; the Go-only matrix measures it separately at 61/64 executable lines (95.31%).
The combined patch result does not establish a Go-only patch-coverage pass.

```bash
COVERAGE_FILE="$PWD/.go-cache/coverage-wizard-state-go" \
PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term --cov-fail-under=80" \
  make test-go-dashboard-wizard-state-parity
mkdir -p .go-cache/coverage-wizard-state-combined
cp .go-cache/coverage-wizard-state-reference \
  .go-cache/coverage-wizard-state-combined/.coverage.reference
cp .go-cache/coverage-wizard-state-go \
  .go-cache/coverage-wizard-state-combined/.coverage.go
cd dashboard
COVERAGE_FILE="$PWD/../.go-cache/coverage-wizard-state-combined/.coverage" \
  .venv/bin/python -m coverage combine --keep ../.go-cache/coverage-wizard-state-combined
COVERAGE_FILE="$PWD/../.go-cache/coverage-wizard-state-combined/.coverage" \
  .venv/bin/python -m coverage xml
cd ..
make test-patch-coverage
```

Full Go race tests, vet, module verification and both static Linux builds pass.
Independent correctness and security reviews found no blocking issue. Affected
Python, YAML, generated-CLI, documentation voice, path-reference and operator-string
checks pass. GNU-first topology checks include untracked files through the
additive inventory wrapper. File budgets pass with the documented starting-SHA
override; no budget entry changed. All new files remain below 400 lines.

Both full `make test` attempts pass shell and Python lint, then fail Markdown lint
on third-party files in the required local uv cache. Changed project Markdown is
checked separately with the same lint configuration. Original tests still match
the frozen starting commit. Worker-specific control HTTP/I/O, production selection,
shipping artifacts and privileged Linux/fleet proof remain pending.
