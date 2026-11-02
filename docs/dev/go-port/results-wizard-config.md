# Wizard config and recovery policy parity

Go now owns the wizard's config preparation, ordered merge, default removal,
machine-name validation and recovery-state decisions. Existing Python tests and
fixtures remain unchanged. The backend still uses Python for HTTP orchestration,
polling, business SQL and the remaining submission/upload/handoff behavior.

## Native boundary

`go/internal/dashboard/wizard/config_prepare.go` and `config_legacy.go` implement
the removed worker/XvB migrations, conflict detection, known-name filtering and
ordered, deduplicated change descriptions. Conflict checks run before migration
and filtering. Known keys retain invalid values for the host parser to reject;
worker arrays retain malformed entries while removing unknown worker fields.
Change descriptions contain field paths, never field values.

`config_ops.go` implements recursive dictionary merge and default removal,
including private-key removal and Python's numeric equality. New machine names
retain the label bounds; unchanged legacy certificate names retain the original
ASCII allowance. Recovery validates remembered change lists, offered disks,
wipe modes and authentication modes without publishing or removing files.

The ordered tree protocol preserves dictionary insertion order, integer/float
types, exact large integers, nonfinite floats and the identity-sensitive NaN
comparisons used inside Python containers. Lone Unicode surrogates in strings,
keys and path summaries use an internal byte tag, preserving the values admitted
by Python's JSON decoder. This does not change the public HTTP encoding.

`go_wizard_config.py` installs the native functions on their original modules and
the server's imported aliases. Python retains generic input-shape normalization
and supplies the runtime schema, legacy alias
defaults, default hostname and spool callback results. It retains JSON response
serialization and the submission transaction/HTTP sequence. Native helper
failures are fatal; none of these five functions falls back to its Python body.
Helper inputs use stdin, with no config values in argv or native counters.

The runtime reference schema is a JSON object. The bridge preserves Python's
primitive/list/null container errors and callback order before dispatch; normal
merge/filter/default-removal decisions execute Go.

The retry handler, remember/remove orchestration, upload policy, document parsing,
submission and installer handoff remain Python. Existing native transaction and
storage helpers retain their prior boundaries. Production container selection
and release/dashboard/appliance shipping integration remain pending.

## Adapters and native proof

Only new files under `tests/go-parity/` adapt the original suites:

- `dashboard_wizard_config_plugin.py` layers over the policy/transaction/channel
  adapters, binds the five native wrappers and makes every captured original
  function body fatal. It counts successful operations and error classes without
  recording input values.
- `dashboard_wizard_config_compare.py` runs separate reference and Go processes
  for migrations, conflict decisions, field filtering, exact key/change order,
  input preservation, merge/default equality, machine-name bounds and recovery
  choices. It includes nonfinite numbers and lone surrogate strings/keys.
- `dashboard_wizard_config_shapes.py` compares malformed container and falsey
  normalization cases, including callback/error ordering.
- `dashboard_wizard_config_guards.py` builds source overlays without changing
  the working source. Empty preparation fails the unchanged legacy-migration
  assertion; an empty recovery decision fails the unchanged failed-install
  refresh assertion. Both controls require the expected assertion failure and
  native-call evidence.

The added Make target runs every original wizard test, the shared defaults tests
and the service config-version tests. Earlier port-added policy, transaction and
channel targets now load this adapter too. The bounded Go CI job includes the
new target. No pre-port test target, fixture, threshold or lint check changed.

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
`a73ffced33800de9435779a9cabef53864455acb` each pass 334 original tests with that
command, using the same installed interpreter and the corresponding package.
The five value comparisons, five shape comparisons and two mutation controls
are supplementary evidence.

```bash
make test-go-dashboard-wizard-config-parity
PITHEAD_IMPL=python PYTEST_XDIST_AUTO_NUM_WORKERS=1 make test-dashboard
PITHEAD_IMPL=go \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin,dashboard_wizard_config_plugin \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_XDIST_AUTO_NUM_WORKERS=1 make test-dashboard
```

The focused target passes 346 tests: the same 334 original tests and 12 new
comparison/control cases. It records 225 successful preparations, 133 merges,
74 default removals, 66 machine-name validations and 68 recovery decisions.
It separately records 16 native machine-name and five native preparation
`ValueError` results. Generic Python input errors are not native successes.

| Check | Reference | Go selection |
|---|---|---|
| Focused original paths | 334 passed at the frozen start and current head | 334 passed with captured original function bodies fatal |
| Added config target | Separate reference processes in the new comparisons | 346 passed, including 12 new comparison/mutation cases |
| Full dashboard | 3719 passed; fresh final source coverage 90.66% | 3719 passed; coverage 82.52% |
| Patch coverage | Fresh reference-only gate fails at 50% | Go-only gate fails at 84%; appended A/B gate passes at 94% |
| Go checks | Reference retained | Full race units, vet, module verification and CGO-free Linux amd64/arm64 command builds passed |
| Full Make | Stops at dependency-cache Markdown lint | Stops at the same gate; no original check changed |

Fresh reference and Go coverage data use separate `COVERAGE_FILE` paths under
`.go-cache/`. Their XML reports are retained and graded independently with the
unchanged `make test-patch-coverage` gate. The appended XML has its own verdict.

The fresh final reference run uses the unchanged full-suite invocation and
threshold, with an isolated XML filename so it can run alongside comparisons:

```bash
cd dashboard
PITHEAD_IMPL=python PYTEST_XDIST_AUTO_NUM_WORKERS=1 .venv/bin/python -m pytest \
  -n auto --cov=mining_dashboard --cov-report=term-missing \
  --cov-report=xml:../.go-cache/coverage-wizard-config-reference-final.xml \
  --cov-fail-under=80
```

The full count includes all 3716 frozen original tests and three snapshot cases
added by an earlier slice. Native counts from xdist workers are not inferred from
the parent process. Local test duration is not performance evidence.

```bash
make go-build go-dashboard-build
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go -C go build -o "../.go-cache/wizard-config-linux-$arch/" ./cmd/pithead ./cmd/dashboard
done
```

Coverage comparisons are appended using the same Go data file:

```bash
PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" \
make test-go-dashboard-overview-parity test-go-dashboard-fleet-parity \
  test-go-dashboard-http-parity test-go-dashboard-storage-parity \
  test-go-dashboard-channel-parity test-go-dashboard-wizard-transaction-parity \
  test-go-dashboard-wizard-policy-parity test-go-dashboard-wizard-config-parity
make test-patch-coverage
```

The tracked-diff gate does not include new untracked files until the operator
commits. Coverage of the new bridge is measured separately in the appended XML.
The eight targets pass 202, 151, 34, 357, 403, 295, 328 and 346 tests,
respectively. The final patch gate covers 39 tracked changed Python files at
94%; the combined Python coverage is 92.35%. The new config bridge measures
93/114 executable lines in that XML; its subprocess comparison edge paths are
separately executed but are not attributed to the parent coverage run. Shared
channel, wizard and policy bridges measure 59/61, 87/88 and 64/67 lines.

Both full Make attempts pass shell lint before failing Markdown lint on
third-party files in the required local uv cache. Changed project Markdown
passes separately. GNU-first topology (including additive enumeration of the
new untracked files), the starting-SHA file-budget override, generated CLI,
Ruff lint/format, YAML, docs voice/path references, operator strings and diff
checks pass. No budget ceiling changed. Independent correctness and security
reviews found no remaining issue in this slice.
No original test file differs from the frozen starting commit.

## Remaining work

Port wizard handoff/ack and retry, then submission/upload/restore and remaining
control HTTP orchestration; add production selection and shipping artifacts with the
reference fallback. Remaining state/earnings and polling also keep this a hybrid
backend. Linux-only CLI, Docker/image, appliance, privileged and fleet proof
remain unavailable or unrun locally.
