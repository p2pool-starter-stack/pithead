# Typed wizard submission parity

Go now supplies typed configuration submission plans, including the preserved
installation shortcut. The original Python handler remains the reference;
existing suites, fixtures and checks are unchanged.

## Native boundary

`go/internal/dashboard/wizard/typed_submission.go` owns these decisions:

- Restate the USB-stick marker and select coordinator versus rig submission.
- Select the special preserved-disk path only for an explicit `wipe=keep`,
  require an offered disk and exact confirmation, and publish only the install
  request. Crafted config and password fields cannot enter config preparation.
- Select accepted auth modes and validate install targets through the existing
  native install policy before invoking a remote-node probe.
- Publish a configured probe report before inspecting its verdict. Rejected
  probes save retry metadata and remove the install trigger. Accepted probes
  publish staging, change metadata, the full attempt, the explicit candidate,
  any install request and finally the active marker, in that order.
- Build accepted/error response plans and the fast-sync warning, preserving
  response field order and requiring actual boolean sync flags.

Changes and probe-error details use the existing tagged `ConfigValue` codec.
This preserves lone surrogates from JSON keys, nulls and non-finite numbers;
using plain Go strings would replace lone surrogates. The bridge restores local
NaN identities before constructing the original JSON response.

`go_wizard_typed.py` retains aiohttp form parsing and response transport. The
unchanged outer `submit` retains authentication, the shared submission lock,
conflict checks and generic setup rollback on `OSError`. Raw document parsing
and duplicate/placeholder diagnostics remain Python. Runtime reference/default
acquisition and sequencing of the existing native prepare/merge/name helpers
also remain Python. Remote probes, remembered-change callbacks and explicit
config materialization remain Python; materialization uses native default
stripping. Action execution calls the same module-level writer hooks as the
reference; their normal implementation uses the native atomic writer.

The bridge checks every expected native phase instead of falling through to the
original handler. Probe awaits and blocking publication retain the original
lock and cancellation behavior. No new network, credential, bind or launch
contract is introduced. This remains a hybrid backend; production selection,
shipping artifacts, remaining control HTTP orchestration and polling are pending.

## Adapters and native proof

Only new files under `tests/go-parity/` adapt the original suites:

- `dashboard_wizard_typed_plugin.py` layers over the rig/restore adapter, makes
  the captured original `_submit_locked` body fatal and counts native phase
  successes and exception classes without recording inputs.
- `dashboard_wizard_typed_compare.py` adds ten separate-process A/B cases.
  They compare exact HTTP bodies/status and file bytes/modes for raw config,
  preserved installs with crafted config, form input, probe rejection, omitted
  wipe settings, malformed reports, surrogate change messages and null,
  surrogate or NaN probe-error details. All paths use temporary local spool,
  restore and handoff directories; probe cases use local mocks.
- `dashboard_wizard_typed_guards.py` builds isolated source overlays. Replacing
  candidate publication with an attempt write fails the unchanged generated
  document test. Reversing keep confirmation fails the unchanged preserved-disk
  test. Both controls require the expected failure and native-call evidence.

The added target and bounded Go CI job run the same original wizard, shared
defaults and config-version tests plus those twelve supplementary cases.
No pre-port Make target, lint rule or threshold changed.

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
reference each pass 334 original tests with the command above, the installed
interpreter and their corresponding packages.

```bash
make test-go-dashboard-wizard-typed-parity
PITHEAD_IMPL=go \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin,dashboard_wizard_typed_plugin \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_XDIST_AUTO_NUM_WORKERS=1 make test-dashboard
```

The focused Go target passes 346 tests: the same 334 originals, ten new paired
comparisons and two mutation controls. Parent-process native counts follow;
subprocess comparison and mutation-worker counts are not inferred.

| Phase | Successful planner responses |
|---|---:|
| Start / route | 125 / 125 |
| Preserved-disk gate | 6 |
| Prepared / install | 66 / 66 |
| Report / verdict | 62 / 62 |
| Accepted / rejected response | 58 / 2 |

No typed-helper exception was recorded. Expected HTTP validation failures are
successful planner responses. Original writer faults still use the earlier
transaction adapter's explicit replace/unlink interpositions and callbacks;
they are not Python submission-planning fallback.

The final reference arm uses the same suite and threshold with isolated XML:

```bash
cd dashboard
PITHEAD_IMPL=python PYTEST_XDIST_AUTO_NUM_WORKERS=1 .venv/bin/python -m pytest \
  -n auto --cov=mining_dashboard --cov-report=term-missing \
  --cov-report=xml:../.go-cache/coverage-wizard-typed-reference-final.xml \
  --cov-fail-under=80
```

Full counts include all 3716 frozen original tests plus three snapshot tests
added by an earlier slice. They do not establish a complete native backend.
Xdist-worker native counts are not inferred from the parent process. Local
test duration is not benchmark evidence. The earlier pre-codec checks are
superseded by fresh final-code A/B coverage and suite runs.

```bash
make go-build go-dashboard-build
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go -C go build -o "../.go-cache/wizard-typed-linux-$arch/" ./cmd/pithead ./cmd/dashboard
done
```

| Check | Reference | Go selection |
|---|---|---|
| Focused original paths | 334 passed at frozen start and current head | Same 334 passed with the original typed handler fatal |
| New typed target | Ten separate-process A/B comparisons | 346 passed, including twelve new cases and two mutation controls |
| Final full dashboard | 3719 passed; 88.65% Python coverage | 3719 passed; 81.28% Python coverage |
| Isolated patch gates | Reference-only gate fails at 41% | Go-only gate fails at 85%; combined A/B gate passes at 92% |
| Go checks | Reference retained | Full race units, vet, module verification and CGO-free Linux amd64/arm64 command builds passed |
| Full Make | Stops at dependency-cache Markdown lint | Stops at the same gate; original checks unchanged |

Fresh final full-arm data uses separate `COVERAGE_FILE` paths under `.go-cache/`.
The unchanged patch gate is graded separately on each arm's XML. The combined
report joins saved reference/Go data, then appends the focused typed target:

```bash
mkdir -p .go-cache/coverage-wizard-typed-combined
cp .go-cache/coverage-wizard-typed-reference-final \
  .go-cache/coverage-wizard-typed-combined/.coverage.reference
cp .go-cache/coverage-wizard-typed-go-final \
  .go-cache/coverage-wizard-typed-combined/.coverage.go
cd dashboard
COVERAGE_FILE="$PWD/../.go-cache/coverage-wizard-typed-combined/.coverage" \
  .venv/bin/python -m coverage combine --keep ../.go-cache/coverage-wizard-typed-combined
cd ..
COVERAGE_FILE="$PWD/.go-cache/coverage-wizard-typed-combined/.coverage" \
PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" \
  make test-go-dashboard-wizard-typed-parity
make test-patch-coverage
```

The combined gate measures 42 tracked changed Python files and 1476 lines,
missing 108. Combined Python coverage is 96.71%. This is combined A/B evidence,
not a Go-only patch-coverage pass. The tracked-diff gate excludes new untracked
files until the operator commits; the new bridge measures 97/99 executable lines
separately, and the shared wizard bridge 93/94. The two missing new bridge lines
are defensive protocol exceptions. Original tests and fixtures remain unchanged
against the frozen starting commit.

Both full Make attempts pass shell lint before failing Markdown lint on
third-party files in the required local uv cache. Changed project Markdown is
checked separately. Correctness and security reviews, including the codec fix,
found no remaining issues. GNU-first topology, including enumeration of
untracked additions, file budget with the starting-SHA override, generated CLI,
Ruff lint/format, YAML, docs voice/path references, operator strings and diff
checks pass. No original check or budget ceiling changed.

Next: remaining wizard preparation/metadata callbacks and control HTTP
orchestration, then production selection and shipping artifacts with reference
fallback. Linux, Docker/image, appliance and privileged proofs remain listed in
[PARITY.md](PARITY.md#unavailable-and-known-host-constraints).
