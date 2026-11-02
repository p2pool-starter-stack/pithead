# Control HTTP policy parity

Go now owns control request validation and response decisions for config reads,
preview, commit, stack upgrade, OS-update, backup and result routes. Python retains
the async transport and I/O callbacks. The original implementations, suites,
fixtures and checks remain unchanged.

## Native boundary

`go/internal/dashboard/controlhttp/` owns these policies:

- Require the control header before reading a mutating request body.
- Require object bodies and proposed configs for preview/commit, while retaining
  their strict document checks and the other routes' plain JSON parsing.
- Accept approval only for the actual boolean `true`, with a closed payout-suffix
  schema. The bridge preserves the original suffix dictionary alias.
- Validate versions using the locked Python 3.11 Unicode 14 decimal-digit table,
  matching its regex rather than Go's newer Unicode table, and
  select only the five existing OS-update actions. Non-hashable actions retain
  their original type error.
- Select submit actions, preview validation transitions and the commit predicate
  that ignores a stale `previewed` result.
- Build pending, completed and error responses, preserving HTTP status, JSON
  shape and insertion order. A result may override the initial request ID while
  retaining its first key position. Result polling accepts any stored JSON shape.

`go_control_http.py` retains request parsing/awaits, authenticated actor reads,
external fleet validators, masked-config reads, submit/wait/result callbacks,
logging and aiohttp response serialization. Preview validates the fleet port
before reading current config or validating new worker entries. Commit waits
outside its submit-error boundary. Upgrade, OS-update and backup never wait
inline; backup never reads a JSON body. UUID and intent validation still use
the existing native control service. Standard-library JSON and the native
document layer retain syntax/duplicate/placeholder behavior.

The bridge validates native response envelopes and keeps helper unavailability
and malformed native plans distinct from client errors. Those faults fail as
backend errors; invalid input and ordinary service-callback failures retain their
original response mapping. There is no Python policy fallback. Installation runs
through `go_control.install()` in the Go dashboard child. Public reference
selection retains the original functions.

Worker detail/apply/upgrade/history handlers remain Python, using the now-native
shared header guard. Config masking, worker-adoption policy, result polling I/O,
wizard preparation sequencing, remaining state/polling, production selection and
shipping remain outside this slice. No host command or live stack is invoked.

## Adapters and native proof

Only new files under `tests/go-parity/` adapt the unchanged suites:

- `dashboard_control_http_plugin.py` layers over the document adapter, makes all
  ten captured original functions fatal, and counts native operations/routes and
  exceptions. Optional traces record operation names only.
- `dashboard_control_http_compare.py` adds six separate-process A/B cases for
  exact HTTP status, stable headers and raw response bytes, callback order and
  short circuiting, approval aliasing, stale-result predicates, Unicode versions,
  strict versus permissive parsing, backup behavior, arbitrary results and ID
  collision/order/non-mapping behavior.
- `dashboard_control_http_guards.py` builds two isolated source overlays.
  Removing the header gate fails the unchanged missing-header test. Breaking the
  commit predicate fails the unchanged stale-preview test. Both controls require
  the expected oracle failure and native operation evidence.
- `dashboard_control_http_availability.py` adds seven Go-specific failure cases.
  Request-body, approval and request helper failures, invalid phases and malformed
  response/action/approval envelopes must produce generic HTTP 500 without submit
  callbacks. They cannot masquerade as client-input or config-read errors. These
  supplementary cases are selected only for Go; they are not original tests.

The additive target and bounded Go CI job run the same original control,
document, adoption and spool suites plus fifteen new cases. No original Make
target, fixture, lint rule or threshold changed.

## Commands and results

Commands use locked Python 3.11 and absolute worktree-local Go/uv caches. No
Docker, live stack or fleet job was used.

```bash
cd dashboard
PITHEAD_IMPL=python .venv/bin/python -m pytest \
  tests/web/test_server_control_routes_enabled.py \
  tests/web/test_server_control_routes_disabled.py tests/web/test_config_commit.py \
  tests/web/test_config_documents.py tests/web/test_worker_adopt_route.py \
  tests/service/test_control_service.py tests/service/test_control_result_polling.py \
  tests/service/test_request_spool.py
cd ..
make test-go-dashboard-control-http-parity
PITHEAD_IMPL=go COVERAGE_FILE="$PWD/.go-cache/coverage-control-http-go-unicode" \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin,dashboard_control_http_plugin \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_XDIST_AUTO_NUM_WORKERS=1 make test-dashboard
```

An isolated archive of `a73ffced33800de9435779a9cabef53864455acb` and the current
reference each pass 157 original focused tests with their corresponding packages.
Full counts include 3716 frozen original tests and three snapshot tests added by
an earlier slice. They do not establish a complete native backend. Parent-process
counts exclude subprocess comparisons and xdist workers. Local duration is not
benchmark evidence. Final-code runs supersede checks before the failure-boundary
and response-envelope fixes. The final Unicode boundary also rejects Kawi and
Nag Mundari digits introduced after the reference's Unicode version, while
retaining Arabic, fullwidth and supplementary mathematical digits.

```bash
cd dashboard
PITHEAD_IMPL=python PYTEST_XDIST_AUTO_NUM_WORKERS=1 \
COVERAGE_FILE="$PWD/../.go-cache/coverage-control-http-reference-schema" \
  .venv/bin/python -m pytest -n auto --cov=mining_dashboard \
    --cov-report=term-missing \
    --cov-report=xml:../.go-cache/coverage-control-http-reference-schema.xml \
    --cov-fail-under=80
cd ..
make go-build go-dashboard-build
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go -C go build -o "../.go-cache/control-http-linux-$arch/" ./cmd/pithead ./cmd/dashboard
done
```

| Check | Result |
| --- | --- |
| Frozen original focused reference | 157 passed |
| Current focused reference | 157 passed |
| Go focused target, originals fatal | 172 passed: 157 originals and 15 additions |
| Full current reference | 3719 passed; 85.58% Python coverage |
| Full Go with storage, overview and control adapters | 3719 passed; 80.11% Python coverage |
| Reference patch coverage alone | 35%; fails the unchanged 90% threshold |
| Go patch coverage alone | 86%; fails the unchanged 90% threshold |
| Combined arms plus focused target | 93% patch coverage; 115/1749 lines missing; passes |
| New bridge measured separately | 191/204 executable lines, 93.63% combined coverage |
| Go race units, vet and module verification | Passed |
| Static Linux builds, both architectures | Passed; execution not proved |

The final focused run records 105 header decisions, 54 request-body decisions,
31 proposed-config checks, five successful approval checks, 17 submit-action
selections, 54 validation transitions, 20 stale-result predicates and 20 completed
response decisions. It also records 13 OS-action decisions, 17 version checks and
41 error responses. Its one native `ValueError` is the expected invalid approval
case. The seven deliberately injected availability failures are separate test
controls, not compatibility fallback. No reference policy call is allowed by the
adapter. These counts describe this run, not all subprocess or full-suite calls.

Coverage data from the two full arms was combined, then the focused target ran
with appended coverage. The combined total Python coverage is 96.66%. The patch
tool sees all 45 tracked changed Python files, but not the new untracked bridge;
the bridge's separate executable-line count above prevents that omission from
being treated as coverage proof. The operator's commit will add it to the patch
inventory. The combined result is not a Go-only patch-coverage pass.

```bash
mkdir -p .go-cache/coverage-control-http-combined
cp .go-cache/coverage-control-http-reference-schema \
  .go-cache/coverage-control-http-combined/.coverage.reference
cp .go-cache/coverage-control-http-go-unicode \
  .go-cache/coverage-control-http-combined/.coverage.go
cd dashboard
COVERAGE_FILE="$PWD/../.go-cache/coverage-control-http-combined/.coverage" \
  .venv/bin/python -m coverage combine --keep ../.go-cache/coverage-control-http-combined
cd ..
COVERAGE_FILE="$PWD/.go-cache/coverage-control-http-combined/.coverage" \
PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" \
  make test-go-dashboard-control-http-parity
make test-patch-coverage
```

Affected Python, YAML, topology, file-budget, generated-CLI, documentation voice,
path-reference and operator-string checks pass. GNU-first topology checks also
include new untracked source through the additive inventory wrapper. Changed
Markdown passes its existing lint configuration. Both full `make test` attempts
pass shell and Python lint, then fail Markdown lint on third-party files in the
required local uv cache. No check or threshold was weakened. Original test files
still match the frozen start; all added cases are named separately above.

Independent adversarial and security reviews of the final source found no
remaining blocking issue in this slice. Native helper failure handling and the
Python-version Unicode boundary were corrected before the final runs. Wizard
preparation sequencing, worker-specific HTTP/I/O and production selection remain
the next backend work; Linux execution, image artifacts and privileged fleet
proof remain pending.
