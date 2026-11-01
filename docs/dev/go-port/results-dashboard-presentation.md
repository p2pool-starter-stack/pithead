# Dashboard presentation parity results

Historical results from the fleet and overview slices; the
[review follow-up](results-review.md) supersedes their gate status and next steps.
The earlier description of the adapter formatting failure as existing was incorrect:
it was introduced on this branch and is fixed in the review follow-up.

## Fleet and resources slice (2026-11-01)

Go now builds worker rows, RigForge chips/inspect rows and release hints, energy
inputs, and host-resource availability/capacity outlook. Worker sorting, skipped
rows, share formatting, power precedence, feed freshness, prices, original sample
times and bounded history resets follow the reference builders. Python supplies
raw snapshots, config descriptors and the existing disk query. State requests
capture those inputs and Go assembles the final three fields without subprocesses.

The resource helper preserves invalid nonfinite samples as invalid numeric inputs
instead of converting them to null. Exact integer conservation avoids rounding
large byte counts into a false valid sample. Native capacity calculations refuse
integer operands beyond exact float range and malformed composites, retaining
Python fallback. Fleet integer formatting and durations retain arbitrary integers;
RigForge timestamp parsing matches Python's accepted forms and rejects fractions.

At this slice's completion, economics, badges, pool/network and base metadata,
polling, SQLite, wizard/control and container selection remained Python. The later
overview slice below supersedes the badge and pool/network display status. The worker
inspect route still uses Python in production; its shared display builders are
also tested directly through Go. Startup on existing/corrupt databases is still
provided by the Python child, not native storage. No performance claim is made.

The new fleet adapter layers over the existing views/metrics/state/HTTP adapters.
Persistent helpers remove process startup from the unchanged 1000-cycle resource
cost test; every call executes Go with fresh inputs and no cached answers.
The HTTP ownership comparison makes Python workers/energy/resources builders
raise while native state still succeeds. Existing suites and fixtures are unchanged.
Under coverage, the adapter reloads the resource module after tracing starts,
then reinstalls native bindings before collection. This records module setup;
the selected resource calculations still execute Go.

Both full runs use `PYTEST_XDIST_AUTO_NUM_WORKERS=1`. Baseline sets
`PITHEAD_IMPL=python`; Go sets `PITHEAD_IMPL=go`,
`PYTEST_PLUGINS=dashboard_fleet_plugin` and `PYTHONPATH` containing absolute
`tests/go-parity` and `dashboard` directories. Local caches are as documented above.
Commands, exits and private logs use `.go-cache/logs/dashboard-state-fleet-*`.
File-budget checks use `FILE_BUDGET_BASE_REF` at the documented starting SHA.

| Command | Baseline | Go selection |
|---|---|---|
| `make test-dashboard` | Pass; 3716 unchanged tests, 96.30% Python coverage | Pass; 3716 unchanged tests, 86.86% Python coverage |
| `make test-go-dashboard-fleet-parity` | Original graph supplies expected values; unchanged modules included in full baseline | Pass; 151 tests: 117 unchanged and 34 new comparisons |
| `make test-patch-coverage` | Fails at 80%; reference mode does not execute Go bridge modules | Initial full-suite-only run fails at 76%; current full suite plus A/B append passes at 92% |
| `go -C go test -race -count=1 ./...`; `go -C go vet ./...` | Additive Go checks | Pass after final numeric fixes |
| `GOOS=linux GOARCH=amd64 go -C go build -o "$PWD/.go-cache/dashboard-linux-amd64" ./cmd/dashboard`; `make go-dashboard-build` | Additive Go builds | Pass after final numeric fixes |
| `make test` | Blocked by branch-added adapter shfmt failure in `tests/go-parity/config_defaults_reference.sh` | Same failure |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend test-fakes` | Pass; 891 frontend tests, 54 fake-daemon tests | Pass; same 891 frontend and 54 fake-daemon tests |

Python coverage does not measure Go code. The patch gate is also run after the
full Go-selected suite followed by the new A/B cases with
`PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" make test-go-dashboard-fleet-parity`.
Those cases execute the original Python graph to obtain their expected values
and execute Go independently for the comparison. This combined coverage is
reported separately from the Go-selected full suite alone; untracked new files
are not included in the pre-commit patch diff.
Ruff check and format check pass for the six changed Python files with
`dashboard/pyproject.toml`. Pinned Markdown lint passes for the five changed
Markdown files, using the existing rules with scoped file globs in
`.go-cache/fleet.markdownlint-cli2.jsonc`. The original aggregate gates are unchanged.

The first focused comparison caught the unsupported swap resource losing its
`bytes` unit. That is corrected. Initial Go build ran during an in-progress Go
edit and failed; the subsequent native/race checks passed. Review also caught
large-integer conversion, malformed-capacity fallback and timestamp grammar
differences before final verification. New comparisons cover those boundaries.
Final review found float share grouping, negative-zero formatting and whitespace
in IP octets differing from Python. These are fixed with Go and A/B regressions.
Security review found full endpoint descriptors entering the internal energy
handoff. It now projects only worker names and watts; a regression excludes
credential and connection fields. Security re-review passes.
Legacy RigForge ages and JSON integer `-0` also have regressions; final
adversarial review passes. Existing Make target behavior is unchanged.

Earlier transport, charts, domain metrics and presentation results are retained
in the [dashboard ledger](results-dashboard.md). Adapter details are in the
[fleet adapter note](adapters-dashboard-fleet.md).

## Overview and badges slice (2026-11-01)

Go now formats the pool/network fields, raffle history and eligibility, update
visibility, and ordered header badges. Python supplies raw snapshots, metrics,
scalar locality/threshold settings, the running version and the existing native
Monero result. Final state completion accepts only the six named overview
operations, flattens the five pool fields and appends the native egress badge
last. No per-request helper process is added.

The badge reads the existing egress summary; egress/topology derivation and Tor
probes remain Python. Wallet-change KV reading/parsing remains Python; the new
Go recent-change helper is unit-tested with supplied KV snapshots only. Earnings,
XvB forecasts/realization, base metadata, polling, SQLite, wizard/control and
container selection remain unported. Existing/corrupt database startup still
uses the Python child. No performance or native-storage claim is made.

The new adapter layers over all earlier adapters. Direct builders execute fresh
Go requests through persistent helpers; A/B expected values restore the original
Python graph. It converts wallet-prefix mock inputs to strings before JSON,
matching Python's display conversion without replacing a test fixture. Under
coverage it reloads the badge module after tracing starts, then reinstalls native
bindings. An HTTP ownership guard disables all six Python builders while native
state still succeeds. Existing tests, fixtures and checks stay unchanged.

Both full suites use one worker. Baseline uses `PITHEAD_IMPL=python`; Go uses
`PITHEAD_IMPL=go`, `PYTEST_PLUGINS=dashboard_overview_plugin` and absolute
`tests/go-parity` and `dashboard` entries in `PYTHONPATH`. Commands and exits are
retained under `.go-cache/logs/dashboard-state-overview-*`.

| Command | Baseline | Go selection |
|---|---|---|
| `make test-dashboard` | Pass; 3716 unchanged tests, 95.90% Python coverage on the frozen source | Pass; 3716 unchanged tests, 86.31% Python coverage |
| `make test-go-dashboard-overview-parity` | Original graph supplies A/B expected values; focused modules included in full baseline | Pass; 202 tests: 171 unchanged and 31 new |
| `make test-patch-coverage` | Frozen reference run fails at 76% | Full Go-selected suite alone fails at 82%; after A/B append passes at 93% |
| `go -C go test -race -count=1 ./...`; `go -C go vet ./...` | Additive Go checks | Pass |
| `make go-dashboard-build`; `GOOS=linux GOARCH=amd64 go -C go build -o "$PWD/.go-cache/overview-dashboard-linux-amd64" ./cmd/dashboard` | Additive Go builds | Pass |
| `make test` | Branch-added adapter shfmt failure | Same failure |
| `make test-go-dashboard-fleet-parity` with coverage append | Original graph supplies A/B expected values | Pass; 151 unchanged prior parity cases |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend test-fakes` | Pass; 891 frontend tests, 54 fake-daemon tests | Pass; same counts |

Python coverage cannot measure native Go code. The patch gate is checked first
on the full Go-selected suite, then after A/B cases append original-Python
expected calculations using `PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term"`
with `make test-go-dashboard-overview-parity test-go-dashboard-fleet-parity`.
These are separate results; new untracked files are outside the pre-commit diff.
The initial reference snapshot passed 3716 tests at 95.72% and its patch gate
failed at 75%; it was rerun on the frozen runtime source for the paired table.
That baseline uses a separate `COVERAGE_FILE` under `.go-cache/`; the combined
Go/A-B coverage XML is restored afterward. Five changed Python files pass Ruff
check/format with `dashboard/pyproject.toml`; four changed Markdown files pass
pinned Markdown lint with existing rules and scoped globs. A final re-export
annotation is runtime-equivalent; no existing lint rule or check changed.

Initial focused failures exposed numeric defaults, null tier comparisons and a
mock wallet-prefix serialization cycle. Go defaults and comparison rules now
match Python, and the additive adapter preserves the mock's string input. New
regressions cover these cases; adversarial and security review pass. One early
worker Go run used system temporary paths and hit existing macOS path assertions;
the documented worktree cache/TMPDIR environment passes those assertions.

Adapter details are in the [overview note](adapters-dashboard-overview.md).
The backend remains in progress; the next state slice is the earnings/XvB chain,
followed by polling and native storage.
