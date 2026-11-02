# Worker HTTP policy parity

Go owns the worker detail, apply and upgrade request/response policies and the
terminal-result history decision. The dashboard remains a hybrid backend.

## Native boundary

`go/internal/dashboard/controlhttp/` now selects worker-name errors, the first
matching worker's RigForge value, upgrade no-op decisions, terminal wait results,
recordable history statuses and response bodies. The semver parser matches the
locked Python 3.11 behavior for whitespace, repeated leading `v`/`V`, suffixes,
the first three components, Unicode 14 digit classes, leading zeros and the
configured integer conversion limit. Invalid live-feed shapes keep their original
HTTP failure behavior.

Worker apply strips credential sentinels with the original depth-six rule.
Only boolean `true` in `__secret__` suppresses `pass` or `tls-fingerprint`;
other values and the original bounded traversal behavior are preserved. The
existing tokenless control service and spool remain the publication boundary.
No direct worker-control connection is added.

`go_worker_http.py` executes plans through the existing helper channel. It replaces
`handle_worker_detail`, `handle_worker_apply`, `handle_worker_upgrade`,
`_record_worker_result` and `_finalize_worker_upgrade`. It preserves header-before-JSON
validation, pending responses, result-ID override order, caller-owned history
worker/changes and terminal-record-before-refresh ordering. Upgrade still submits
a background finalizer; apply still waits inline. Unknown/running statuses are
not recorded. Native helper faults and malformed plans raise backend errors
without running captured reference bodies.

Python retains HTTP/JSON transport, the freshness clock and `feed_stale`, worker
detail/history/chart builders, window parsing, service/wait I/O, background-task
execution, refresh callbacks and storage calls. The original client credential
filter also remains for other callers. Passing its direct unit tests does not
prove this route's Go filter. Worker payload builders, refresh polling and
production container selection are not claimed native by this slice.

## Adapters and native proof

New files under `tests/go-parity/` supply supplementary evidence:

- `dashboard_worker_http_plugin.py` layers over the earlier adapters, installs
  the worker policy bridge and makes all five captured original bodies fatal.
  It records worker-operation successes and errors. Optional traces contain
  operation/route labels only.
- `dashboard_worker_http_compare.py` adds seven separate-process A/B cases for
  HTTP status/type/body bytes, header/JSON/name errors, pending/result collisions,
  callback order, nested sentinels, stale/no-op upgrades, Unicode/oversized
  versions, malformed feeds, finalizer failures and history ownership/vocabulary.
  One in-process case checks six unavailable/malformed-plan failures.
- `dashboard_worker_http_guards.py` adds two isolated source-overlay mutations
  and three reference-selection sentinels. Disabling history selection or
  credential stripping must fail the unchanged
  `test_worker_apply_spools_tokenless_intent_and_records_history` oracle with
  one expected failure and the relevant native trace. Unset, Bash and Python
  selection must never invoke the sentinel native binary.
- `dashboard_worker_http_failures.py` adds eleven in-process error-boundary cases.
  Native detail, submit and background-predicate failures must escape curated
  callback-error handling; ordinary callback failures retain their original
  responses or background behavior. Nonrecordable results must skip persistence.
  Status responses carrying continuation phases must fail before submission or
  history recording. Removing that source check makes all three new regressions fail.
  This control runs the source with only the two new validator lines removed in
  an isolated process, requiring pytest exit 1 and three failures.

The additive `test-go-dashboard-worker-http-parity` target is included in the
bounded Go CI job. Its original inputs contain 29 direct worker HTTP tests and
98 service, spool, credential, refresh and detail-input tests, totaling 127.
Those supporting tests retain Python callbacks where described above. No original
suite, fixture, threshold or lint rule is edited, replaced or weakened.

## Commands and results

Runs use locked Python 3.11, offline locked tools and absolute worktree-local
Go/uv caches. No Docker, live stack, fleet job or benchmark is used. Static Linux
builds do not establish Linux execution or image validation.

```bash
make test-go-dashboard-worker-http-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go -C go build -o "../.go-cache/worker-http-linux-$arch/" ./cmd/pithead ./cmd/dashboard
done
```

The focused target passes 151 tests: 127 originals plus 24 additions.
The 127-original run records two detail-name, thirteen terminal-predicate, seventeen live,
27 name, seventeen no-op, thirteen record and three strip operations, with no
worker-native errors. Counts exclude A/B and mutation subprocesses, xdist
workers and deliberate helper interpositions. Both source-mutation controls pass
by observing the required failures in the unchanged test.

Frozen `a73ffced33800de9435779a9cabef53864455acb` and current reference arms each
pass the same 127 focused originals. The full reference suite passes 3719 tests:
3716 frozen originals and three tests added by earlier port slices. The native
matrix adds six earlier wizard-state boundary cases, one worker boundary
case and eleven failure-boundary cases, excluding A/B/reference/mutation subprocesses.
All 3737 assertions pass, but the unchanged 80% Python coverage gate fails at 79.62%. Precision two makes
the exit decision reflect that measured value; no threshold is reduced.

| Check | Result |
| --- | --- |
| Frozen/current reference and Go focused originals | 127 passed each |
| Focused Go target | 151 passed |
| Full reference | 3719 passed; 83.72% coverage |
| Full native matrix | 3737 assertions passed; 79.62% coverage; gate fails |
| Native-only patch coverage | 86%; 272/2080 lines missing; gate fails |
| Focused A/B comparison append | 151 passed; cumulative 84.65% coverage |
| Comparison-appended patch coverage | 87%; 256/2080 lines missing; gate fails |
| Combined reference/comparison patch coverage | 92%; 158/2080 lines missing; passes |
| New worker bridge, native matrix | 114/114 executable lines; 100% |

The full native command uses the unchanged Make recipe and extra boundary tests:

```bash
PITHEAD_IMPL=go PYTEST_XDIST_AUTO_NUM_WORKERS=1 \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin,dashboard_worker_http_plugin \
PYTEST_ADDOPTS="tests $PWD/tests/go-parity/dashboard_wizard_state_compare.py::test_native_plan_failures_raise_without_reference_fallback $PWD/tests/go-parity/dashboard_worker_http_compare.py::test_native_worker_plan_failures_are_fail_closed $PWD/tests/go-parity/dashboard_worker_http_failures.py --cov-precision=2" \
COVERAGE_FILE="$PWD/.go-cache/coverage-worker-http-reviewed/.coverage" make test-dashboard
```

Appending the focused target also measures reference subprocess execution, so
its 84.65% total is comparison coverage. Combining actual reference and comparison
datasets gives 96.47% total coverage and a passing 92% patch gate, with all 48
tracked changed Python files present. This does not establish a Go-only coverage
pass. The new untracked worker bridge is outside the patch inventory until the
operator commits; its separate measurement is listed above.

```bash
COVERAGE_FILE="$PWD/.go-cache/coverage-worker-http-reviewed/.coverage" \
PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term --cov-fail-under=80 --cov-precision=2" \
  make test-go-dashboard-worker-http-parity
```

The combined gate uses explicit measured inputs, retaining their datasets:

```bash
cd dashboard
COVERAGE_FILE="$PWD/../.go-cache/worker-http-paired.coverage" \
  .venv/bin/python -m coverage combine --keep \
    ../.go-cache/coverage-worker-http-reviewed-reference/.coverage \
    ../.go-cache/coverage-worker-http-reviewed/.coverage
COVERAGE_FILE="$PWD/../.go-cache/worker-http-paired.coverage" \
  .venv/bin/python -m coverage xml
cd ..
make test-patch-coverage
```

Full Go race tests, vet, module verification and both static Linux builds pass.
Original tests still match the frozen starting commit. Full `make test` attempts
in reference and Go modes pass shell/Python lint and stop at Markdown lint on
third-party files in the required local uv cache. Existing checks remain intact.
Production selection, shipping/image validation and privileged Linux/fleet proof
remain pending.

Correctness review found a status-plus-continuation plan gap in the shared
control bridge. The validator now rejects it before submission or persistence;
three regressions and a source-removal control establish that boundary. Independent
correctness and security reviews clear the final runtime source. Affected Python,
YAML, file-budget, generated-CLI, GNU-first topology, documentation voice, path and
operator-string checks pass. The untracked-file topology wrapper also passes.
Changed project Markdown is checked separately using the unchanged configuration.
