# Dashboard parity results

## Dashboard HTTP foundation slice (2026-11-01)

The operator's 15:30Z priority change moves the dashboard ahead of further CLI
refinement. The credential publication slice is finished and archived above.
The immediate target is a dashboard that serves its contracts on existing and
corrupt databases; the current HTTP foundation is partial.

`make go-dashboard-build` builds `go/bin/dashboard`. It binds to the same
loopback endpoint and serves the complete application route/method table,
conditional control-route registration, security headers, HTML shell, preview
and static assets in Go. Unknown routes return 404; wrong methods return 405
with the reference Allow header. Shell caching, JavaScript MIME, file metadata,
HEAD, ranges, conditional responses and missing-file behavior have direct
Python comparisons. Preview retains its opt-in gate and no-store policy.

Every registered data/control handler still delegates to Python. A normal Go
launch starts the unchanged Python application with an inherited private
listener; it still owns state, polling, services and SQLite. An optional
reference override accepts only literal loopback HTTP addresses. Go drains
requests and terminates/reaps its own reference child. This is a hybrid server,
not a native state or storage implementation, and no performance claim is made.
The normal dashboard container command remains Python; selection is not wired.

The new pytest plugin puts Go in front of each unchanged Python app fixture and
shares its state references. It forwards fallback requests to that original
app, fails if the Go child is absent, and reaps the exact child. A test-only
restart reflects preview environment changes made after app creation. Original
Python service/view unit tests still exercise Python; a full-suite pass must
not be interpreted as native backend proof. Seven new comparisons use a sentinel
reference to prove native transport ownership and compare actual Python/Go
responses and exercise the actual Python-child bootstrap against an isolated
aiohttp stub, including signal shutdown and exact child-PID reaping. No existing
test, fixture or browser asset changes.

Baseline uses `PITHEAD_IMPL=python make test-dashboard`. Go uses the same command
with `PITHEAD_IMPL=go`, `PYTEST_PLUGINS=dashboard_http_plugin` and `PYTHONPATH`
containing the absolute `tests/go-parity` and `dashboard` directories. Runs use
worktree caches and an absent Docker socket. Private records are under
`.go-cache/logs/dashboard-http-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-dashboard` | Pass; 3716 tests, 97.42% Python coverage | Pass; same 3716 tests unchanged, 97.38% Python coverage; hybrid adapter required |
| Six unchanged shell/static/security/disabled-control/layout/preview modules named in the new Make target | Pass; 19 tests | Pass; same 19 tests unchanged |
| `make test-go-dashboard-http-parity` | Python responses compared within the supplementary cases | Pass; 19 unchanged tests and 7 new cases |
| `make test-patch-coverage` after the Go-selected dashboard suite | Not separately rerun | Pass; 97% over the branch diff; Python coverage is not Go coverage |
| `make test-fakes` | Pass; 54 tests | Pass; same 54 tests, Python client contracts |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` with `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb` | Pass; 891 frontend tests | Same result |
| `make test` | Exit 2 at unchanged `config_defaults_reference.sh` shfmt finding; ShellCheck passes | Same result |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML pass; exit 2 at 22 third-party cache Markdown findings | Same result |

Native checks pass: `go -C go test -json -race -count=1
./internal/dashboard/...`, `go -C go test ./...`, `go -C go vet ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/dashboard-linux-amd64
./cmd/dashboard` (compile only).
The original Linux stack/container oracle remains unavailable. Actual reference
child bootstrap is tested with an inherited listener and an isolated aiohttp
application; no live stack or real collector is started. Successful migration
and corrupt-database recovery by Go remain unproven. Rare static
conditional/range combinations and precompressed sibling negotiation are not
yet covered; no precompressed assets are shipped today.

All 638 Python files pass locked Ruff lint/formatting. Dashboard extras are
restored with `uv sync --locked --project dashboard --extra dev --extra test`.
Changed Go files pass `gofmt -l`. Changed Markdown passes `npx --yes
markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs`
with the four changed document paths. Paired `make lint-file-budget
lint-docs-voice` passes after the ledger update, using the starting-SHA budget
override above.

Independent security and adversarial reviews pass after static normalization,
special-file handling and loopback-only reference checks. A real Go launch
against an isolated Python fixture proves listener inheritance, native shell,
delegated JSON, graceful parent exit and child reaping. Frozen-source checksums
confirm the final tested implementation and new comparisons remain unchanged.
Existing tests, fixtures and Make behavior are unchanged; two additive targets
build and test the dashboard. The aggregate Make gate and unavailable
Linux/Docker/fleet checks retain the limits below.

## Native chart and JSON slice (2026-11-01)

Go now computes the history chart within `/api/state`: range filtering, all five
averaging windows, adaptive bucket averages, outage gaps, nearest-share markers,
events, raffle wins and capped payout markers. It also assembles miner connection
and XvB standby JSON and renders the Prometheus exposition. Private inputs contain
raw config/domain/storage values rather than those three rendered responses.

This is still a hybrid backend. Python supplies storage reads and config,
computes domain metrics, assembles every other state section, and runs all polling
and control services. A private bridge replaces only the chart builder with an
input capture, so each normal state request reads history once; Go computes the
chart and assembles the final JSON response. Supported chart inputs stay native;
unavailable/malformed/oversized private inputs retain the public Python handler.
Collection errors yield sanitized public failures. No performance claim is made.

The bridge is installed only in the Go-launched Python child or explicit parity
adapter. It uses the existing private loopback listener; its paths are absent
from the public Go route table. Credentials and browser headers are not forwarded
to other hosts, redirects are refused, input reads are bounded and connection
credentials retain no-store. The default Python launch and existing public
handlers stay unchanged. The container selection switch remains pending.

The new pytest plugin layers over the unchanged HTTP plugin, adds private inputs
to the original app, and routes direct `build_chart` calls through the Go helper.
It materializes marker iterables as the Python algorithm does, so existing mock
fixtures remain unchanged. Native HTTP state handling calls Go directly without
spawning a helper. New comparisons force all four original public handlers to
fail, proving native route ownership; they compare charts against Python across
ranges, windows, downsampling and marker cases and check one history read and
sanitized failures. Existing tests, fixtures and browser assets stay unchanged.

Baseline uses `PITHEAD_IMPL=python make test-dashboard`. Go uses the same command
with `PITHEAD_IMPL=go`, `PYTEST_PLUGINS=dashboard_state_plugin` and `PYTHONPATH`
containing the absolute `tests/go-parity` and `dashboard` directories. Worktree
caches and an absent Docker socket are used. Private records are under
`.go-cache/logs/dashboard-state-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-dashboard` | Pass; 3716 unchanged tests, 96.99% Python coverage | Pass; same 3716 tests, 90.40% Python coverage through the state adapter |
| `make test-go-dashboard-state-parity` | Original Python chart compared within the new cases; selected modules included in the baseline suite | Pass; 66 unchanged chart/route tests and 26 new cases |
| `make test-go-dashboard-http-parity` | Earlier baseline retained in the HTTP ledger | Pass; all 26 prior transport tests unchanged |
| `make test-patch-coverage` after the Go-selected suite | Not separately rerun | Pass; 90% over the branch diff |
| `make test-fakes` | Pass; 54 tests | Pass; same 54 tests; Python client contracts |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` with `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb` | Pass; 891 frontend tests | Same result |
| `make test` | Exit 2 at unchanged `config_defaults_reference.sh` shfmt finding; ShellCheck passes | Same result |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML pass; exit 2 at 22 third-party cache Markdown findings | Same result |

Native checks pass: `go -C go test -json -race -count=1
./internal/dashboard/...`, `go -C go test ./...`, `go -C go vet ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/dashboard-linux-amd64
./cmd/dashboard` (compile only). Python coverage is reference/bridge coverage,
not Go coverage. Go storage migration/recovery, polling, remaining state/domain
computation and control are not yet implemented. Original Linux/container and
Go-enabled fleet verdicts remain unavailable for this unpushed slice.

All 642 Python files pass locked Ruff lint/formatting. Dashboard extras are
restored with `uv sync --locked --project dashboard --extra dev --extra test`.
Changed Go files pass `gofmt -l`. Changed Markdown passes `npx --yes
markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs`
with the four changed document paths. Paired `make lint-file-budget
lint-docs-voice` passes after the ledger update with the starting-SHA override.

Independent security and adversarial reviews pass. Frozen-source checksums
confirm the final tested implementation and new comparisons remain unchanged.
Existing tests, fixtures and Make behavior remain unchanged. The new Make target
adds the state/JSON slice; the prior transport target still passes unchanged.
Earlier HTTP-foundation evidence is preserved in the linked dashboard ledger.

## Native dashboard domain slice (2026-11-01)

Go now computes domain metrics for `/api/state` and `/metrics`: P2Pool and XvB
routed averages, credited tiers, sustainable donation thresholds, worker counts,
PPLNS shares/weight, cadence/luck, sync and stale-state values. Prometheus reject
percentages also use Go. Raw numeric values and Python float types are preserved
across the private protocol. Config helpers still supply each node's locality.

For state requests, Python collects one history/snapshot input, Go calculates
metrics, and a private POST returns those metrics and that history to Python for
the remaining presentation sections. Go then computes the chart and writes the
public JSON. Production handlers do not spawn helper processes per request.
Private calls retain the existing literal-loopback transport, no redirects or
browser headers, and 64 MiB bounds. Public `/_go/*` routes remain unavailable.
Unsupported inputs retain Python fallback; collection failures stay sanitized.
Share-weight and sync-height integer overflow refuses native processing.

This remains a hybrid backend. Python owns all polling, SQLite, the remaining
state presentation, wizard/control services and config collection. Normal
container launch remains Python. Startup on existing/corrupt databases is still
Python behavior; there is no native storage or full Go backend verdict yet.
No performance claim is made; the separate performance work is untouched.

The new metrics plugin layers over the unchanged state/HTTP adapters. It sends
direct metrics and average calls to Go, reconstructing the existing dataclasses;
all existing tests and fixtures stay unchanged. New comparisons retain the real
Python average functions for the expected result. A guard makes all Python
`build_metrics` aliases raise while both public routes still succeed, proving
native computation through the production bridge.

Baseline is `PITHEAD_IMPL=python make test-dashboard`. Go runs the same target
with `PITHEAD_IMPL=go`, `PYTEST_PLUGINS=dashboard_metrics_plugin` and `PYTHONPATH`
containing the absolute `tests/go-parity` and `dashboard` directories. Logs and
command/exit records are private under `.go-cache/logs/dashboard-state-domain-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-dashboard` | Pass; 3716 unchanged tests, 96.80% Python coverage | Pass; same 3716 tests, 89.59% Python coverage through the metrics adapter |
| `pytest -q dashboard/tests/service/test_metrics.py dashboard/tests/web/test_server_state_api.py dashboard/tests/web/test_server_metrics_endpoint.py` using the locked interpreter | Pass; 65 tests | Included unchanged in the full Go suite and focused target |
| `make test-go-dashboard-domain-parity` | Original Python compared in the new cases; selected modules included above | Pass; 121 unchanged metrics/chart/route tests plus 34 comparisons, 155 total |
| `make test-go-dashboard-state-parity test-go-dashboard-http-parity` | Prior baseline retained in the dashboard ledger | Pass; prior 92 and 26 cases unchanged |
| `make test-patch-coverage` after the Go suite | Not separately rerun | Pass; 90% over the tracked branch diff; untracked new files are outside this pre-commit diff |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend test-fakes` with the starting-SHA budget override | Pass; 891 frontend tests and 54 fake-daemon contracts | Same result; fakes exercise Python clients |
| `make test` | Exit 2 at unchanged `config_defaults_reference.sh` shfmt finding; ShellCheck passes | Same result |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML pass; exit 2 at 22 third-party cache Markdown findings | Same result |

The full Go suite caught the separate config-helper locality contract; the
implementation now honors it without changing that test. Review also found null
timestamps silently treated as zero; Go now refuses those rows and new HTTP
regressions prove the reference 500 behavior. Protocol decoding also refuses
null scalar config/clock values while preserving nullable Tari locality. The helper lookup and a new
comparison's expected display string were corrected too.

Native checks pass: `go -C go test -race -count=1 ./internal/dashboard/...`,
`go -C go test ./...`, `go -C go vet ./...` and `GOOS=linux GOARCH=amd64
go -C go build -o ../.go-cache/dashboard-domain-linux-amd64 ./cmd/dashboard`
(compile only). All 645 Python files pass locked Ruff lint/formatting; changed
Markdown passes the pinned linter. Python coverage measures the reference and
bridge, not Go; the new input module has 100% measured Python line coverage.
The locked environment is restored with both dev/test extras.

Independent security and adversarial reviews pass after the failure-path fixes.
Source checksums and the final audit verify unchanged existing tests, fixtures,
bench-owned paths and prior Make behavior; only the new target is added. Every
new file stays below 400 lines. Earlier chart/JSON and transport results remain
in the [dashboard ledger](results-dashboard.md).

## Native dashboard presentation slice before fleet/resources (2026-11-01)

Go now formats system, proxy summary, Tari, sync and Monero sections. It also
builds share/reject series, blocks, payouts, disk growth, XvB history, hashrate
and cadence. Series filtering, summed delta buckets and averaged gauge buckets
retain Python's window bounds, ordering, null/default values and rounding.
Both payout confirmation flags still gate the original storage reads.

Infrastructure sections are computed beside native domain metrics, then handed
to the Python state assembler. Python captures raw series inputs; Go builds the
final fields and chart before writing public JSON. There is no per-request
helper subprocess. The Monero result also supplies the sync card's database
size, so the two sections share the same native value. Private series fields
and operations are explicitly paired; malformed inputs retain Python fallback.

At this slice's completion, workers, RigForge, energy, host resources,
earnings/badges, pool/network formatting and other state metadata remained Python.
The later fleet/resource slice in [PARITY.md](PARITY.md#native-dashboard-fleet-and-resources-slice-2026-11-01)
supersedes the worker, RigForge, energy and host-resource status below.
The production mode palette still supplies tokens from Python; its Go helper is
covered by unchanged direct tests. Polling, SQLite, wizard/control and normal
container launch remain Python. Native startup on existing/corrupt databases,
container selection and a full Go backend are not yet proved. No performance
claim is made; the separate performance work is untouched.

The new views adapter layers over prior metrics/state/HTTP adapters and invokes
Go for the existing direct builders and private series helpers, preserving their
signatures and existing dataclasses/namespaces. New comparisons restore the
original Python call graph for expected results. An HTTP ownership guard makes
Python metrics, infrastructure and final series builders raise while native
`/api/state` still succeeds. Existing tests, fixtures and browser assets stay
unchanged. Go units cover handoff consistency and malformed-field fallback.
The adapter initializes the views facade under pytest-cov before collection,
then restores its Go bindings; the coverage gates remain unchanged.
This fixes an initial 87% patch-coverage failure caused by facade imports before
coverage started; the reference aliases and native dispatch remain the same.

Baseline uses `PITHEAD_IMPL=python make test-dashboard`. Go uses the same target
with `PITHEAD_IMPL=go`, `PYTEST_PLUGINS=dashboard_views_plugin` and `PYTHONPATH`
containing the absolute `tests/go-parity` and `dashboard` directories. Commands,
exits and private logs are under `.go-cache/logs/dashboard-state-views-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-dashboard` | Pass; 3716 unchanged tests, 96.58% Python coverage | Pass; same 3716 tests, 88.82% Python coverage through the views adapter |
| `make test-go-dashboard-views-parity` | Original Python compared in new cases; selected modules included above | Pass; 157 unchanged tests and 27 comparisons |
| `make test-go-dashboard-domain-parity test-go-dashboard-state-parity test-go-dashboard-http-parity` | Prior baselines retained in the dashboard ledger | Pass; 155, 92 and 26 tests respectively |
| `uv run --locked --project dashboard --extra test python -m pytest -p dashboard_views_plugin dashboard/tests/service/xvb/test_numeric_properties.py` | Pass; 10 unchanged property tests | Pass; same 10 tests through the persistent Go average helper |
| `make test-patch-coverage` after the Go suite | Not separately rerun | Pass; 91% over the tracked branch diff; new untracked files are outside this pre-commit diff |

The unchanged cadence tests caught zero timestamps incorrectly formatted as an
epoch time; they now remain `Never`. A new proxy comparison caught division
rounded after multiplying by 100 instead of before it: 19,993 accepted and seven
rejected must display `0.03%`. Both implementations now agree on that boundary.
New cases cover falsy timestamps, large durations, millisecond timestamps beyond
64 bits, exact integer buckets and cancellation above float precision. Invalid
storage rows and numeric strings preserve the reference failure/fallback paths.
The first Make invocation named a test in the wrong folder; the new target was
corrected without changing the original suite.

Automatic-worker Go runs also hit 200 ms Hypothesis deadlines in the two average
property tests; the failures reported elapsed time, not a value mismatch. With
two workers, baseline passed 3716 and Go passed 3715; the unchanged Python
trickled-read test took 4.6 seconds against its four-second bound. One worker
still hit a 281 ms average-helper startup spike, replaying at 52 ms. The new
adapter therefore keeps one Go average process per worker and sends every
input to the unchanged native calculation, without memoization. Its stream
protocol has new Go tests; the original one-shot helper and adapter stay intact.
The final paired full runs use `PYTEST_XDIST_AUTO_NUM_WORKERS=1` in both modes.
Assertions, examples, deadlines, coverage thresholds and Make recipes are unchanged.

`go -C go test ./...`, `go -C go vet ./...` and
`go -C go test -race -count=1 ./internal/dashboard/...` pass with local caches.
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/dashboard-views-linux-amd64
./cmd/dashboard` also passes. Paired project
checks pass for file budgets, CLI generation, documentation voice, paths,
operator strings, 891 frontend tests and 54 fake-daemon tests. The file-budget
check uses `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb`.
Both selections ran `make lint-file-budget lint-pithead-build lint-docs-voice
lint-path-references lint-operator-strings test-frontend test-fakes`.

`make test` stops in unchanged `config_defaults_reference.sh` formatting in both
modes. Separate Python, JavaScript and YAML lint passes in both modes; Markdown
lint reports the same 22 third-party cache findings. The four changed Markdown
files pass those same pinned rules separately; final scoped Ruff checks pass.
No check was weakened.
Independent security and correctness reviews passed. Python coverage measures
the reference and bridge, not Go. Earlier transport, chart/JSON and domain results remain in the
[dashboard ledger](results-dashboard.md).
