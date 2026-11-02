# Dashboard raw-document validation parity

Go now owns the dashboard's duplicate-key and placeholder checks, path and
diagnostic formatting, and host-error-record refusal. These checks serve wizard
submissions, control requests and host configuration readers. Existing Python
suites, fixtures and checks remain unchanged.

## Native boundary

`go/internal/dashboard/wizard/documents.go` traverses ordered object pairs and
arrays, rejects the first duplicate at the original depth-first position and
reports only its key/path. It refuses placeholder string leaves after the
original Unicode uppercase transformation, including expanding ligatures.
Path and diagnostic formatting match Python's ASCII JSON escaping for controls,
quotes, Unicode and lone surrogates. Host configuration refuses a top-level
`_config_document_error` record with the original string or generic error.

`go_documents.py` retains the standard-library JSON decoder, including syntax
errors, byte decoding, non-finite numbers and integer limits. Syntax decoding
finishes before duplicate validation, preserving error precedence. The original
object-pairs marker and exception classes stay available. Native faults populate
the same exception type, attributes, message and diagnostic method without
calling the original validation or formatting functions.
Non-string private-helper keys use the standard library's JSON serialization as
a lexical input; Go applies the original path slicing and escaping. Truthy
non-string parents retain Python's string conversion.

For the duplicate phase, Python retains scalar and other passthrough values as
opaque identities. Go returns the decoded shape and alias placement paths;
the bridge restores the original leaf objects. This preserves private `_decode`
passthrough dictionaries and nested aliases as well as NaN identity. Placeholder
checks receive the actual decoded values through the existing tagged codec.
Streams, transport and response serialization remain Python.

Native installation runs through both wizard installation and the Go dashboard
child's control installation. Public reference selection retains the original
implementation. No production container selector or shipping artifact is added
by this slice. Preparation sequencing, probes, control HTTP orchestration,
remaining state/earnings and polling remain hybrid or Python as listed in PARITY.

## Adapters and native proof

Only new files under `tests/go-parity/` adapt original suites:

- `dashboard_documents_plugin.py` layers over the wizard-values adapter, makes
  all seven original functions/methods fatal, and counts native operations and
  helper exceptions. Optional mutation traces contain operation names only.
- `dashboard_documents_compare.py` adds five separate-process A/B cases covering
  exact exception types/messages/attributes, JSON syntax-error positions,
  duplicate precedence, escaped paths, surrogates, non-finite values, Unicode
  placeholders, host records, streams, private decode aliases and non-string
  private-helper parents/keys.
- `dashboard_documents_guards.py` builds two isolated source overlays. Disabling
  duplicate detection fails all six unchanged duplicate tests; the tagged codec's
  duplicate defense also refuses the corrupted result. Disabling placeholder
  refusal fails the unchanged control-escaping test. Both controls require native
  operation traces and the expected failing oracle result.

The additive target and bounded Go CI job run the same original document,
control, host-watch, wizard, shared-defaults and config-version suites plus those
seven new cases. No original Make target, fixture, lint rule or threshold changed.

## Commands and results

Commands use the locked Python 3.11 environment and absolute worktree-local
Go/uv caches. No Docker, live stack or fleet job was used.

```bash
cd dashboard
PITHEAD_IMPL=python .venv/bin/python -m pytest \
  tests/config/test_documents.py tests/web/test_config_documents.py \
  tests/web/test_config_commit.py tests/web/test_server_control_routes_enabled.py \
  tests/web/test_server_control_routes_disabled.py \
  tests/service/test_data_service_watch_host_config.py tests/web/test_wizard*.py \
  tests/web/test_config_defaults.py tests/service/test_config_version.py
cd ..
make test-go-dashboard-documents-parity
PITHEAD_IMPL=go COVERAGE_FILE="$PWD/.go-cache/coverage-documents-go-final" \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin,dashboard_documents_plugin \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_XDIST_AUTO_NUM_WORKERS=1 make test-dashboard
```

An isolated archive of `a73ffced33800de9435779a9cabef53864455acb` and the current
reference each pass 530 original focused tests with their corresponding packages.
Full counts include 3716 frozen original tests and three snapshot tests added by
an earlier slice; they do not establish a complete native backend. Parent-process
counts exclude subprocess comparisons and xdist-worker counts. Local test
duration is not benchmark evidence.

```bash
cd dashboard
PITHEAD_IMPL=python PYTEST_XDIST_AUTO_NUM_WORKERS=1 \
COVERAGE_FILE="$PWD/../.go-cache/coverage-documents-reference-final" \
  .venv/bin/python -m pytest -n auto --cov=mining_dashboard \
    --cov-report=term-missing --cov-report=xml:../.go-cache/coverage-documents-reference-final.xml \
    --cov-fail-under=80
cd ..
make go-build go-dashboard-build
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go -C go build -o "../.go-cache/documents-linux-$arch/" ./cmd/pithead ./cmd/dashboard
done
```

| Check | Reference | Go selection |
|---|---|---|
| Focused original paths | 530 passed at frozen start and current head | Same 530 passed with seven original bodies fatal |
| New document target | Five separate-process A/B comparisons | 537 passed, including seven new cases and two source mutations |
| Final full dashboard | 3719 passed; 87.21% Python coverage | 3719 passed; 80.90% Python coverage |
| Isolated patch gates | Reference-only gate fails at 36% | Go-only gate fails at 86% |
| Go checks | Reference retained | Full race units, vet, module verification and CGO-free Linux amd64/arm64 command builds passed |
| Full Make | Stops at dependency-cache Markdown lint | Stops at the same gate; original checks unchanged |

Final-code runs supersede the earlier checks before the private-helper fix.
The focused target records successful native responses below, including known
validation faults. No documents-helper exception occurred in that parent process.

| Operation | Responses |
|---|---:|
| Decode/alias placement | 241 |
| Diagnostic | 27 |
| Host record | 24 |
| Placeholders | 214 |

Direct private path checks and source mutations run in separate processes and
are not added to those parent counts. The mutation traces record the required
six native failed decode attempts and one native placeholder attempt.

Coverage data from the final full arms is saved independently. Each arm's XML
is graded with the unchanged patch gate, then the reports are combined and the
focused document target appended:

```bash
mkdir -p .go-cache/coverage-documents-combined
cp .go-cache/coverage-documents-reference-final \
  .go-cache/coverage-documents-combined/.coverage.reference
cp .go-cache/coverage-documents-go-final \
  .go-cache/coverage-documents-combined/.coverage.go
cd dashboard
COVERAGE_FILE="$PWD/../.go-cache/coverage-documents-combined/.coverage" \
  .venv/bin/python -m coverage combine --keep ../.go-cache/coverage-documents-combined
cd ..
COVERAGE_FILE="$PWD/.go-cache/coverage-documents-combined/.coverage" \
PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" \
  make test-go-dashboard-documents-parity
make test-patch-coverage
```

The combined A/B patch gate passes at 93%: 44 tracked changed Python files,
1664 measured lines and 111 missing lines. Combined Python coverage is 96.72%.
This is combined evidence, not a Go-only patch-coverage pass. The tracked-diff
gate excludes the new untracked bridge until the operator commits; it measures
80/84 executable lines separately in the XML. Missing lines are non-string-key
lexical normalization, ignored non-JSON leaves, a defensive fault-kind guard and
the direct private path wrapper. The new paired cases exercise the private
paths in separate processes without subprocess coverage collection. The shared
wizard bridge measures 97/98 lines and control bridge 33/33.

Correctness review identified non-string private-helper key handling; the final
implementation and new paired regression resolve it, and re-review passes.
Security review and its delta recheck found no remaining issues. GNU-first
topology, including untracked additions, file budget with the starting-SHA
override, generated CLI, Ruff lint/format, YAML, docs voice/path references,
operator strings, changed Markdown and diff checks pass. The original tests and
fixtures remain unchanged against the frozen starting commit.

Both full Make attempts pass shell lint before failing Markdown lint on
third-party text in the required local uv cache. No original check or budget
ceiling changed. Full Linux CLI, Docker/image, appliance and privileged evidence
remain unavailable locally as listed in
[PARITY.md](PARITY.md#unavailable-and-known-host-constraints).

Next: wizard preparation sequencing and remaining control HTTP orchestration,
then production selection and release/dashboard/appliance shipping artifacts
with the Bash/Python reference fallback.
